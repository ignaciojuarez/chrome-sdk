// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_prompts.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/file_select_helper.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/ui/cobble/cobble_client_certificates.h"
#include "chrome/browser/ui/cobble/cobble_extension_install_prompt.h"
#include "components/strings/grit/components_strings.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/file_select_listener.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/javascript_dialog_type.h"
#include "net/base/auth.h"
#include "third_party/blink/public/mojom/choosers/file_chooser.mojom.h"
#include "ui/base/l10n/l10n_util.h"
#include "url/gurl.h"
#include "url/origin.h"

struct CCSJavaScriptDialogRequest {
  uint64_t id = 0;
  CCSPageRef page = nullptr;
  content::GlobalRenderFrameHostToken frame_token;
  content::GlobalRenderFrameHostId frame_id;
  content::JavaScriptDialogManager::DialogClosedCallback callback;
  std::string requesting_origin;
  std::string top_level_origin;
  std::string frame_token_string;
  std::string message;
  std::string default_prompt;
  CCSJavaScriptDialogKind kind = CCS_JAVASCRIPT_DIALOG_ALERT;
  bool is_reload = false;
};

struct CCSHTTPAuthRequest final : public content::LoginDelegate {
  CCSHTTPAuthRequest(CCSPageRef request_page,
                     content::WebContents* contents,
                     const net::AuthChallengeInfo& auth_info,
                     const content::GlobalRequestID& global_request_id,
                     bool request_primary_navigation,
                     bool request_navigation,
                     const GURL& request_url,
                     bool request_first_attempt,
                     LoginAuthRequiredCallback request_callback);
  ~CCSHTTPAuthRequest() override;
  void Publish();

  uint64_t id;
  CCSPageRef page;
  raw_ptr<content::WebContents> contents;
  content::GlobalRenderFrameHostToken document_token;
  LoginAuthRequiredCallback callback;
  std::string request_url;
  std::string challenger_origin;
  std::string top_level_origin;
  std::string scheme;
  std::string realm;
  std::string document_token_string;
  int32_t network_process_id;
  int32_t network_request_id;
  bool is_proxy;
  bool first_attempt;
  bool primary_navigation;
  bool navigation;
  base::WeakPtrFactory<CCSHTTPAuthRequest> weak_factory{this};
};

struct CCSFileChooserRequest {
  uint64_t id = 0;
  CCSPageRef page = nullptr;
  raw_ptr<content::WebContents> contents = nullptr;
  content::GlobalRenderFrameHostToken frame_token;
  content::GlobalRenderFrameHostId frame_id;
  scoped_refptr<content::FileSelectListener> listener;
  std::string requesting_origin;
  std::string top_level_origin;
  std::string frame_token_string;
  std::string title;
  std::string default_filename;
  std::vector<std::string> accepted_types;
  CCSFileChooserMode mode = CCS_FILE_CHOOSER_OPEN;
};

struct CCSExternalProtocolRequest {
  uint64_t id = 0;
  CCSPageRef page = nullptr;
  raw_ptr<content::WebContents> contents = nullptr;
  content::GlobalRenderFrameHostToken frame_token;
  content::GlobalRenderFrameHostId frame_id;
  std::string target_url;
  std::string requesting_origin;
  std::string top_level_origin;
  std::string frame_token_string;
  bool user_gesture = false;
  bool primary_main_frame = false;
  bool fenced_frame = false;
};

namespace {

struct PromptState {
  std::vector<std::unique_ptr<CCSJavaScriptDialogRequest>> javascript;
  std::vector<CCSHTTPAuthRequest*> auth;
  std::vector<std::unique_ptr<CCSFileChooserRequest>> files;
  std::vector<std::unique_ptr<CCSExternalProtocolRequest>> external_protocols;
};

PromptState& State() {
  static base::NoDestructor<PromptState> state;
  return *state;
}

bool FrameIsLive(CCSPageRef page,
                 content::WebContents* contents,
                 const content::GlobalRenderFrameHostToken& token,
                 const content::GlobalRenderFrameHostId& id) {
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromFrameToken(token);
  return cobble_chromium::PageWebContents(page) == contents && frame &&
         frame == content::RenderFrameHost::FromID(id) &&
         content::WebContents::FromRenderFrameHost(frame) == contents;
}

void StateChanged(content::WebContents* contents) {
  if (contents) {
    cobble_chromium::BrowserPageStateChanged(contents);
  }
}

CCSJavaScriptDialogRequest* FindJavaScript(
    CCSJavaScriptDialogRequestRef request) {
  for (const auto& candidate : State().javascript) {
    if (candidate.get() == request) return candidate.get();
  }
  return nullptr;
}

void FinishJavaScript(uint64_t id,
                      bool accept,
                      std::u16string prompt,
                      bool notify_cancelled) {
  auto& requests = State().javascript;
  auto found = std::find_if(requests.begin(), requests.end(),
                            [id](const auto& request) { return request->id == id; });
  if (found == requests.end()) return;
  std::unique_ptr<CCSJavaScriptDialogRequest> request = std::move(*found);
  requests.erase(found);
  CCSPageRef page = request->page;
  content::WebContents* contents = cobble_chromium::PageWebContents(page);
  base::WeakPtr<content::WebContents> contents_alive =
      contents ? contents->GetWeakPtr() : nullptr;
  const content::GlobalRenderFrameHostToken frame_token = request->frame_token;
  const content::GlobalRenderFrameHostId frame_id = request->frame_id;
  StateChanged(contents);
  if (notify_cancelled && cobble_chromium::Client().javascript_dialog_cancelled) {
    cobble_chromium::Client().javascript_dialog_cancelled(
        cobble_chromium::Client().user_data, request.get(), request->id);
  }
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromFrameToken(frame_token);
  const bool page_accepts_result =
      request->kind == CCS_JAVASCRIPT_DIALOG_BEFORE_UNLOAD
          ? contents_alive &&
                cobble_chromium::PageForWebContents(contents) == page
          : cobble_chromium::PageAcceptsPromptResult(page, contents);
  const bool frame_is_live =
      page_accepts_result && frame &&
      frame == content::RenderFrameHost::FromID(frame_id) &&
      content::WebContents::FromRenderFrameHost(frame) == contents;
  if (!frame_is_live) {
    accept = false;
    prompt.clear();
  }
  std::move(request->callback).Run(accept, prompt);
}

CCSFileChooserRequest* FindFile(CCSFileChooserRequestRef request) {
  for (const auto& candidate : State().files) {
    if (candidate.get() == request) return candidate.get();
  }
  return nullptr;
}

CCSHTTPAuthRequest* FindAuth(CCSHTTPAuthRequestRef request) {
  auto found = std::find(State().auth.begin(), State().auth.end(), request);
  return found == State().auth.end() ? nullptr : *found;
}

CCSExternalProtocolRequest* FindExternal(
    CCSExternalProtocolRequestRef request) {
  for (const auto& candidate : State().external_protocols) {
    if (candidate.get() == request) return candidate.get();
  }
  return nullptr;
}

void CancelFile(uint64_t id, bool notify_cancelled) {
  auto& requests = State().files;
  auto found = std::find_if(requests.begin(), requests.end(),
                            [id](const auto& request) { return request->id == id; });
  if (found == requests.end()) return;
  std::unique_ptr<CCSFileChooserRequest> request = std::move(*found);
  requests.erase(found);
  content::WebContents* contents = request->contents;
  if (notify_cancelled && cobble_chromium::Client().file_chooser_cancelled) {
    cobble_chromium::Client().file_chooser_cancelled(
        cobble_chromium::Client().user_data, request.get(), request->id);
  }
  request->listener->FileSelectionCanceled();
  StateChanged(contents);
}

void CancelAuth(CCSHTTPAuthRequest* request, bool notify_cancelled) {
  request = FindAuth(request);
  if (!request || request->callback.is_null()) return;
  CCSHTTPAuthRequestRef handle = request;
  const uint64_t id = request->id;
  content::WebContents* contents = request->contents;
  auto callback = std::move(request->callback);
  std::erase(State().auth, request);
  if (notify_cancelled && cobble_chromium::Client().http_auth_cancelled) {
    cobble_chromium::Client().http_auth_cancelled(
        cobble_chromium::Client().user_data, handle, id);
  }
  StateChanged(contents);
  std::move(callback).Run(std::nullopt);
}

void CancelExternal(uint64_t id, bool notify_cancelled) {
  auto& requests = State().external_protocols;
  auto found = std::find_if(requests.begin(), requests.end(),
                            [id](const auto& request) {
                              return request->id == id;
                            });
  if (found == requests.end()) return;
  std::unique_ptr<CCSExternalProtocolRequest> request = std::move(*found);
  requests.erase(found);
  content::WebContents* contents = request->contents;
  StateChanged(contents);
  if (notify_cancelled &&
      cobble_chromium::Client().external_protocol_cancelled) {
    cobble_chromium::Client().external_protocol_cancelled(
        cobble_chromium::Client().user_data, request.get(), request->id);
  }
}

void CancelAllForShutdown() {
  while (!State().javascript.empty())
    FinishJavaScript(State().javascript.front()->id, false, {}, true);
  while (!State().auth.empty()) CancelAuth(State().auth.front(), true);
  while (!State().files.empty()) CancelFile(State().files.front()->id, true);
  while (!State().external_protocols.empty())
    CancelExternal(State().external_protocols.front()->id, true);
}

class DialogManager final : public content::JavaScriptDialogManager {
 public:
  void RunJavaScriptDialog(content::WebContents* contents,
                           content::RenderFrameHost* frame,
                           content::JavaScriptDialogType type,
                           const std::u16string& message,
                           const std::u16string& default_prompt,
                           DialogClosedCallback callback,
                           bool* suppressed) override;
  void RunBeforeUnloadDialog(content::WebContents* contents,
                             content::RenderFrameHost* frame,
                             bool is_reload,
                             DialogClosedCallback callback) override;
  bool HandleJavaScriptDialog(content::WebContents* contents,
                              bool accept,
                              const std::u16string* prompt) override;
  void CancelDialogs(content::WebContents* contents, bool reset_state) override;

  static void Publish(std::unique_ptr<CCSJavaScriptDialogRequest> request);
};

void DialogManager::Publish(
    std::unique_ptr<CCSJavaScriptDialogRequest> request) {
  CCSJavaScriptDialogRequest* handle = request.get();
  CCSPageRef page = handle->page;
  State().javascript.push_back(std::move(request));
  content::WebContents* contents = cobble_chromium::PageWebContents(page);
  StateChanged(contents);
  if (FindJavaScript(handle) != handle ||
      cobble_chromium::PageForWebContents(contents) != page) {
    return;
  }
  const CCSJavaScriptDialogRequestV1 value = {
      .struct_size = sizeof(CCSJavaScriptDialogRequestV1),
      .request_id = handle->id,
      .kind = handle->kind,
      .requesting_origin_utf8 = handle->requesting_origin.c_str(),
      .top_level_origin_utf8 = handle->top_level_origin.c_str(),
      .frame_process_id = handle->frame_id.child_id.value(),
      .frame_routing_id = handle->frame_id.frame_routing_id,
      .frame_token_utf8 = handle->frame_token_string.c_str(),
      .message_utf8 = handle->message.c_str(),
      .default_prompt_utf8 = handle->default_prompt.c_str(),
      .is_reload = static_cast<uint8_t>(handle->is_reload),
  };
  cobble_chromium::Client().javascript_dialog_requested(
      cobble_chromium::Client().user_data, page, handle, &value);
  cobble_chromium::RegisterShutdownCallback(&CancelAllForShutdown);
}

void DialogManager::RunJavaScriptDialog(
    content::WebContents* contents,
    content::RenderFrameHost* frame,
    content::JavaScriptDialogType type,
    const std::u16string& message,
    const std::u16string& default_prompt,
    DialogClosedCallback callback,
    bool* suppressed) {
  CCSPageRef page = cobble_chromium::PageForWebContents(contents);
  if (!page || !frame || cobble_chromium::IsStopping() ||
      !cobble_chromium::Client().javascript_dialog_requested ||
      message.size() > 65536 || default_prompt.size() > 65536) {
    *suppressed = true;
    return;
  }
  *suppressed = false;
  auto request = std::make_unique<CCSJavaScriptDialogRequest>();
  request->id = cobble_chromium::NextPromptRequestID();
  request->page = page;
  request->frame_token = frame->GetGlobalFrameToken();
  request->frame_id = frame->GetGlobalId();
  request->callback = std::move(callback);
  request->requesting_origin = frame->GetLastCommittedOrigin().Serialize();
  request->top_level_origin = frame->GetMainFrame()->GetLastCommittedOrigin().Serialize();
  request->frame_token_string = request->frame_token.frame_token.value().ToString();
  request->message = base::UTF16ToUTF8(message);
  request->default_prompt = base::UTF16ToUTF8(default_prompt);
  request->kind = static_cast<CCSJavaScriptDialogKind>(type);
  Publish(std::move(request));
}

void DialogManager::RunBeforeUnloadDialog(
    content::WebContents* contents,
    content::RenderFrameHost* frame,
    bool is_reload,
    DialogClosedCallback callback) {
  CCSPageRef page = cobble_chromium::PageForWebContents(contents);
  if (!page || !frame || cobble_chromium::IsStopping() ||
      !cobble_chromium::Client().javascript_dialog_requested) {
    std::move(callback).Run(false, {});
    return;
  }
  auto request = std::make_unique<CCSJavaScriptDialogRequest>();
  request->id = cobble_chromium::NextPromptRequestID();
  request->page = page;
  request->frame_token = frame->GetGlobalFrameToken();
  request->frame_id = frame->GetGlobalId();
  request->callback = std::move(callback);
  request->requesting_origin = frame->GetLastCommittedOrigin().Serialize();
  request->top_level_origin = frame->GetMainFrame()->GetLastCommittedOrigin().Serialize();
  request->frame_token_string = request->frame_token.frame_token.value().ToString();
  request->kind = CCS_JAVASCRIPT_DIALOG_BEFORE_UNLOAD;
  request->is_reload = is_reload;
  Publish(std::move(request));
}

uint64_t PublishFormRepostConfirmation(
    content::WebContents* contents,
    content::RenderFrameHost* frame,
    base::OnceCallback<void(bool)> callback) {
  if (callback.is_null()) {
    return 0;
  }
  CCSPageRef page = cobble_chromium::PageForWebContents(contents);
  if (!page || !frame || cobble_chromium::IsStopping() ||
      !cobble_chromium::Client().javascript_dialog_requested ||
      cobble_chromium::PageHasPendingPromptOrMedia(page)) {
    std::move(callback).Run(false);
    return 0;
  }
  auto request = std::make_unique<CCSJavaScriptDialogRequest>();
  request->id = cobble_chromium::NextPromptRequestID();
  const uint64_t id = request->id;
  request->page = page;
  request->frame_token = frame->GetGlobalFrameToken();
  request->frame_id = frame->GetGlobalId();
  request->callback = base::BindOnce(
      [](base::OnceCallback<void(bool)> decision, bool accept,
         const std::u16string&) { std::move(decision).Run(accept); },
      std::move(callback));
  request->requesting_origin = frame->GetLastCommittedOrigin().Serialize();
  request->top_level_origin =
      frame->GetMainFrame()->GetLastCommittedOrigin().Serialize();
  request->frame_token_string =
      request->frame_token.frame_token.value().ToString();
  request->message =
      base::UTF16ToUTF8(l10n_util::GetStringUTF16(IDS_HTTP_POST_WARNING));
  request->kind = CCS_JAVASCRIPT_DIALOG_FORM_REPOST;
  request->is_reload = true;
  DialogManager::Publish(std::move(request));
  return id;
}

bool DialogManager::HandleJavaScriptDialog(
    content::WebContents* contents,
    bool accept,
    const std::u16string* prompt) {
  auto found = std::find_if(State().javascript.begin(), State().javascript.end(),
                            [contents](const auto& request) {
                              return cobble_chromium::PageWebContents(request->page) == contents;
                            });
  if (found == State().javascript.end()) return false;
  FinishJavaScript((*found)->id, accept, prompt ? *prompt : std::u16string(),
                   true);
  return true;
}

void DialogManager::CancelDialogs(content::WebContents* contents, bool) {
  std::vector<uint64_t> ids;
  for (const auto& request : State().javascript) {
    if (cobble_chromium::PageWebContents(request->page) == contents)
      ids.push_back(request->id);
  }
  for (uint64_t id : ids) FinishJavaScript(id, false, {}, true);
}

}  // namespace

uint64_t cobble_chromium::RequestFormRepostConfirmation(
    content::WebContents* contents,
    content::RenderFrameHost* frame,
    base::OnceCallback<void(bool)> callback) {
  return PublishFormRepostConfirmation(contents, frame, std::move(callback));
}

void cobble_chromium::CancelFormRepostConfirmation(uint64_t request_id) {
  auto found = std::find_if(
      State().javascript.begin(), State().javascript.end(),
      [request_id](const auto& request) {
        return request->id == request_id &&
               request->kind == CCS_JAVASCRIPT_DIALOG_FORM_REPOST;
      });
  if (found != State().javascript.end()) {
    FinishJavaScript(request_id, false, {}, true);
  }
}

CCSHTTPAuthRequest::CCSHTTPAuthRequest(
    CCSPageRef request_page,
    content::WebContents* request_contents,
    const net::AuthChallengeInfo& auth_info,
    const content::GlobalRequestID& global_request_id,
    bool request_primary_navigation,
    bool request_navigation,
    const GURL& requested_url,
    bool request_first_attempt,
    LoginAuthRequiredCallback request_callback)
    : id(cobble_chromium::NextPromptRequestID()),
      page(request_page),
      contents(request_contents),
      document_token(request_contents->GetPrimaryMainFrame()->GetGlobalFrameToken()),
      callback(std::move(request_callback)),
      request_url(requested_url.spec()),
      challenger_origin(auth_info.challenger.Serialize()),
      top_level_origin(request_contents->GetPrimaryMainFrame()->GetLastCommittedOrigin().Serialize()),
      scheme(auth_info.scheme),
      realm(auth_info.realm),
      document_token_string(document_token.frame_token.value().ToString()),
      network_process_id(global_request_id.child_id.GetUnsafeValue()),
      network_request_id(global_request_id.request_id),
      is_proxy(auth_info.is_proxy),
      first_attempt(request_first_attempt),
      primary_navigation(request_primary_navigation),
      navigation(request_navigation) {
  State().auth.push_back(this);
}

CCSHTTPAuthRequest::~CCSHTTPAuthRequest() {
  const bool pending = !callback.is_null();
  std::erase(State().auth, this);
  if (pending) {
    StateChanged(contents);
  }
  if (pending && cobble_chromium::Client().http_auth_cancelled) {
    cobble_chromium::Client().http_auth_cancelled(
        cobble_chromium::Client().user_data, this, id);
  }
}

void CCSHTTPAuthRequest::Publish() {
  if (callback.is_null() || cobble_chromium::PageWebContents(page) != contents)
    return;
  CCSPageRef page_handle = page;
  const CCSHTTPAuthRequestV1 value = {
      .struct_size = sizeof(CCSHTTPAuthRequestV1), .request_id = id,
      .request_url_utf8 = request_url.c_str(),
      .challenger_origin_utf8 = challenger_origin.c_str(),
      .top_level_origin_utf8 = top_level_origin.c_str(),
      .scheme_utf8 = scheme.c_str(), .realm_utf8 = realm.c_str(),
      .document_frame_token_utf8 = document_token_string.c_str(),
      .network_process_id = network_process_id,
      .network_request_id = network_request_id,
      .is_proxy = static_cast<uint8_t>(is_proxy),
      .first_attempt = static_cast<uint8_t>(first_attempt),
      .primary_main_frame_navigation = static_cast<uint8_t>(primary_navigation),
      .navigation = static_cast<uint8_t>(navigation),
  };
  StateChanged(contents);
  if (FindAuth(this) != this ||
      cobble_chromium::PageForWebContents(contents) != page_handle) {
    return;
  }
  cobble_chromium::Client().http_auth_requested(
      cobble_chromium::Client().user_data, page_handle, this, &value);
}

extern "C" uint8_t CCSJavaScriptDialogResolve(
    CCSJavaScriptDialogRequestRef request,
    uint8_t accept,
    const char* prompt_utf8) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  request = FindJavaScript(request);
  if (!request ||
      !FrameIsLive(request->page, cobble_chromium::PageWebContents(request->page),
                   request->frame_token, request->frame_id)) return 0;
  std::u16string prompt = prompt_utf8 ? base::UTF8ToUTF16(prompt_utf8) : std::u16string();
  if (prompt.size() > 65536) return 0;
  FinishJavaScript(request->id, accept != 0, std::move(prompt), false);
  return 1;
}

extern "C" uint8_t CCSHTTPAuthResolve(CCSHTTPAuthRequestRef request,
                                       const char* username_utf8,
                                       const char* password_utf8) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  request = FindAuth(request);
  if (!request || request->callback.is_null() || !username_utf8 || !password_utf8 ||
      cobble_chromium::PageWebContents(request->page) != request->contents ||
      request->contents->GetPrimaryMainFrame()->GetGlobalFrameToken() != request->document_token)
    return 0;
  std::u16string username = base::UTF8ToUTF16(username_utf8);
  std::u16string password = base::UTF8ToUTF16(password_utf8);
  if (username.size() > 4096 || password.size() > 4096) return 0;
  CCSPageRef page = request->page;
  content::WebContents* contents = request->contents;
  base::WeakPtr<content::WebContents> contents_alive = contents->GetWeakPtr();
  const content::GlobalRenderFrameHostToken document_token =
      request->document_token;
  auto callback = std::move(request->callback);
  std::erase(State().auth, request);
  StateChanged(contents);
  content::RenderFrameHost* main_frame =
      contents_alive ? contents->GetPrimaryMainFrame() : nullptr;
  if (!contents_alive ||
      cobble_chromium::PageForWebContents(contents) != page ||
      !cobble_chromium::PageAcceptsPromptResult(page, contents) || !main_frame ||
      main_frame->GetGlobalFrameToken() != document_token) {
    std::move(callback).Run(std::nullopt);
    return 1;
  }
  std::move(callback).Run(net::AuthCredentials(username, password));
  return 1;
}

extern "C" uint8_t CCSHTTPAuthCancel(CCSHTTPAuthRequestRef request) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  request = FindAuth(request);
  if (!request || request->callback.is_null()) return 0;
  CancelAuth(request, false);
  return 1;
}

extern "C" uint8_t CCSFileChooserResolve(
    CCSFileChooserRequestRef request,
    const char* const* paths_utf8,
    size_t path_count) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  request = FindFile(request);
  if (!request ||
      !FrameIsLive(request->page, request->contents, request->frame_token,
                   request->frame_id)) return 0;
  if (!paths_utf8 || path_count == 0) {
    CancelFile(request->id, false);
    return 1;
  }
  const bool multiple = request->mode == CCS_FILE_CHOOSER_OPEN_MULTIPLE;
  const bool directory = request->mode == CCS_FILE_CHOOSER_UPLOAD_FOLDER ||
                         request->mode == CCS_FILE_CHOOSER_OPEN_DIRECTORY;
  const bool save = request->mode == CCS_FILE_CHOOSER_SAVE;
  if ((!multiple && path_count != 1) || path_count > 1024) return 0;
  // The C ABI supplies this pointer/count pair; the cap above bounds the only
  // unsafe construction, and span keeps all subsequent access checked.
  auto path_values = UNSAFE_BUFFERS(base::span(paths_utf8, path_count));
  std::vector<base::FilePath> paths;
  paths.reserve(path_values.size());
  for (const char* path_utf8 : path_values) {
    if (!path_utf8) return 0;
    base::FilePath path = base::FilePath::FromUTF8Unsafe(path_utf8);
    if (!path.IsAbsolute() ||
        (directory ? !base::DirectoryExists(path)
                   : save ? path.BaseName().empty() ||
                                !base::DirectoryExists(path.DirName())
                          : !base::PathExists(path) ||
                                base::DirectoryExists(path)))
      return 0;
    paths.push_back(std::move(path));
  }
  auto& requests = State().files;
  auto found = std::find_if(requests.begin(), requests.end(),
                            [request](const auto& value) { return value.get() == request; });
  std::unique_ptr<CCSFileChooserRequest> owned = std::move(*found);
  requests.erase(found);
  content::WebContents* contents = owned->contents;
  if (owned->mode == CCS_FILE_CHOOSER_UPLOAD_FOLDER) {
    FileSelectHelper::EnumerateDirectory(contents,
                                         std::move(owned->listener), paths[0]);
    StateChanged(contents);
    return 1;
  }
  std::vector<blink::mojom::FileChooserFileInfoPtr> files;
  for (const base::FilePath& path : paths) {
    files.push_back(blink::mojom::FileChooserFileInfo::NewNativeFile(
        blink::mojom::NativeFileInfo::New(path, std::u16string(),
                                          std::vector<std::u16string>())));
  }
  owned->listener->FileSelected(
      std::move(files), base::FilePath(),
      static_cast<blink::mojom::FileChooserParams::Mode>(owned->mode));
  StateChanged(contents);
  return 1;
}

extern "C" uint8_t CCSExternalProtocolResolve(
    CCSExternalProtocolRequestRef request,
    uint8_t allow) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  request = FindExternal(request);
  if (!request ||
      !FrameIsLive(request->page, request->contents, request->frame_token,
                   request->frame_id)) {
    return 0;
  }
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromFrameToken(request->frame_token);
  if (!frame || !frame->IsActive()) return 0;
  // Approval only transfers ownership of the handoff back to the host. Native
  // must never invoke Chromium's external launcher for an embedded page.
  (void)allow;
  CancelExternal(request->id, false);
  return 1;
}

namespace cobble_chromium {

content::JavaScriptDialogManager* GetJavaScriptDialogManager() {
  static base::NoDestructor<DialogManager> manager;
  return manager.get();
}

std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* contents,
    const content::GlobalRequestID& request_id,
    bool primary_main_frame_navigation,
    bool navigation,
    const GURL& url,
    bool first_auth_attempt,
    content::LoginDelegate::LoginAuthRequiredCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CCSPageRef page = PageForWebContents(contents);
  if (!page || IsStopping() || !Client().http_auth_requested) return nullptr;
  auto request = std::make_unique<CCSHTTPAuthRequest>(
      page, contents, auth_info, request_id, primary_main_frame_navigation,
      navigation, url, first_auth_attempt, std::move(callback));
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&CCSHTTPAuthRequest::Publish,
                                request->weak_factory.GetWeakPtr()));
  RegisterShutdownCallback(&CancelAllForShutdown);
  return request;
}

bool HandleFileChooser(content::RenderFrameHost* frame,
                       scoped_refptr<content::FileSelectListener> listener,
                       const blink::mojom::FileChooserParams& params) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  content::WebContents* contents = frame ? content::WebContents::FromRenderFrameHost(frame) : nullptr;
  CCSPageRef page = PageForWebContents(contents);
  const auto mode = static_cast<CCSFileChooserMode>(params.mode);
  if (!page || !frame || !listener || IsStopping() ||
      !Client().file_chooser_requested) {
    if (listener) listener->FileSelectionCanceled();
    return true;
  }
  auto request = std::make_unique<CCSFileChooserRequest>();
  request->id = NextPromptRequestID(); request->page = page;
  request->contents = contents; request->frame_token = frame->GetGlobalFrameToken();
  request->frame_id = frame->GetGlobalId(); request->listener = std::move(listener);
  request->requesting_origin = frame->GetLastCommittedOrigin().Serialize();
  request->top_level_origin = frame->GetMainFrame()->GetLastCommittedOrigin().Serialize();
  request->frame_token_string = request->frame_token.frame_token.value().ToString();
  request->title = base::UTF16ToUTF8(params.title);
  request->default_filename = params.default_file_name.BaseName().AsUTF8Unsafe();
  request->mode = mode;
  for (const auto& type : params.accept_types)
    request->accepted_types.push_back(base::UTF16ToUTF8(type));
  CCSFileChooserRequest* handle = request.get();
  CCSPageRef request_page = page;
  State().files.push_back(std::move(request));
  StateChanged(contents);
  if (FindFile(handle) != handle ||
      PageForWebContents(contents) != request_page) {
    return true;
  }
  std::vector<const char*> accepted;
  for (const auto& type : handle->accepted_types) accepted.push_back(type.c_str());
  const CCSFileChooserRequestV1 value = {
      .struct_size = sizeof(CCSFileChooserRequestV1), .request_id = handle->id,
      .mode = handle->mode,
      .requesting_origin_utf8 = handle->requesting_origin.c_str(),
      .top_level_origin_utf8 = handle->top_level_origin.c_str(),
      .frame_process_id = handle->frame_id.child_id.value(),
      .frame_routing_id = handle->frame_id.frame_routing_id,
      .frame_token_utf8 = handle->frame_token_string.c_str(),
      .title_utf8 = handle->title.c_str(),
      .default_filename_utf8 = handle->default_filename.c_str(),
      .accepted_types_utf8 = accepted.empty() ? nullptr : accepted.data(),
      .accepted_type_count = accepted.size(),
  };
  Client().file_chooser_requested(Client().user_data, request_page, handle,
                                  &value);
  RegisterShutdownCallback(&CancelAllForShutdown);
  return true;
}

void HandleExternalProtocol(
    content::WebContents* contents,
    content::RenderFrameHost* initiator,
    const GURL& target_url,
    const std::optional<url::Origin>& initiating_origin,
    bool user_gesture,
    bool primary_main_frame,
    bool fenced_frame) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  CCSPageRef page = PageForWebContents(contents);
  const auto scheme = target_url.scheme();
  const bool forbidden_scheme =
      scheme == "http" || scheme == "https" || scheme == "file" ||
      scheme == "about" || scheme == "data" || scheme == "javascript" ||
      scheme == "blob" || scheme == "filesystem" || scheme == "chrome" ||
      scheme == "chrome-extension" || scheme == "devtools";
  if (!page || !initiator || !initiator->IsActive() ||
      content::WebContents::FromRenderFrameHost(initiator) != contents ||
      !initiating_origin || initiating_origin->opaque() ||
      initiator->GetLastCommittedOrigin() != *initiating_origin ||
      initiator->GetMainFrame()->GetLastCommittedOrigin().opaque() ||
      !target_url.is_valid() || !target_url.has_scheme() ||
      target_url.spec().empty() || target_url.spec().size() > 8192 ||
      forbidden_scheme || !user_gesture || !primary_main_frame || fenced_frame ||
      IsStopping() || !Client().external_protocol_requested ||
      PageHasPendingPrompt(contents)) {
    return;
  }

  auto request = std::make_unique<CCSExternalProtocolRequest>();
  request->id = NextPromptRequestID();
  request->page = page;
  request->contents = contents;
  request->frame_token = initiator->GetGlobalFrameToken();
  request->frame_id = initiator->GetGlobalId();
  request->target_url = target_url.spec();
  request->requesting_origin = initiating_origin->Serialize();
  request->top_level_origin =
      initiator->GetMainFrame()->GetLastCommittedOrigin().Serialize();
  request->frame_token_string =
      request->frame_token.frame_token.value().ToString();
  request->user_gesture = user_gesture;
  request->primary_main_frame = primary_main_frame;
  request->fenced_frame = fenced_frame;
  CCSExternalProtocolRequest* handle = request.get();
  State().external_protocols.push_back(std::move(request));
  StateChanged(contents);
  if (FindExternal(handle) != handle || PageForWebContents(contents) != page) {
    return;
  }
  const CCSExternalProtocolRequestV1 value = {
      .struct_size = sizeof(CCSExternalProtocolRequestV1),
      .request_id = handle->id,
      .target_url_utf8 = handle->target_url.c_str(),
      .requesting_origin_utf8 = handle->requesting_origin.c_str(),
      .top_level_origin_utf8 = handle->top_level_origin.c_str(),
      .frame_process_id = handle->frame_id.child_id.value(),
      .frame_routing_id = handle->frame_id.frame_routing_id,
      .frame_token_utf8 = handle->frame_token_string.c_str(),
      .user_gesture = static_cast<uint8_t>(handle->user_gesture),
      .primary_main_frame =
          static_cast<uint8_t>(handle->primary_main_frame),
      .fenced_frame = static_cast<uint8_t>(handle->fenced_frame),
  };
  Client().external_protocol_requested(Client().user_data, page, handle,
                                       &value);
  RegisterShutdownCallback(&CancelAllForShutdown);
}

bool PageHasPendingPrompt(content::WebContents* contents) {
  if (PageHasPendingExtensionInstallPrompt(contents)) return true;
  for (const auto& request : State().javascript)
    if (PageWebContents(request->page) == contents) return true;
  for (const auto* request : State().auth)
    if (request->contents == contents && !request->callback.is_null()) return true;
  for (const auto& request : State().files)
    if (request->contents == contents) return true;
  for (const auto& request : State().external_protocols)
    if (request->contents == contents) return true;
  return PageHasPendingClientCertificate(contents);

}

void CancelPagePrompts(content::WebContents* contents,
                       bool cancel_extension_install) {
  base::WeakPtr<content::WebContents> alive = contents->GetWeakPtr();
  if (cancel_extension_install)
    CancelExtensionInstallPromptsForPage(contents);
  if (!alive) return;
  std::vector<uint64_t> javascript;
  for (const auto& request : State().javascript)
    if (PageWebContents(request->page) == contents) javascript.push_back(request->id);
  for (uint64_t id : javascript) FinishJavaScript(id, false, {}, true);
  std::vector<CCSHTTPAuthRequest*> auth;
  for (auto* request : State().auth)
    if (request->contents == contents) auth.push_back(request);
  for (auto* request : auth) CancelAuth(request, true);
  std::vector<uint64_t> files;
  for (const auto& request : State().files)
    if (request->contents == contents) files.push_back(request->id);
  for (uint64_t id : files) CancelFile(id, true);
  std::vector<uint64_t> external_protocols;
  for (const auto& request : State().external_protocols)
    if (request->contents == contents)
      external_protocols.push_back(request->id);
  for (uint64_t id : external_protocols) CancelExternal(id, true);
  CancelClientCertificatesForPage(contents);
}

}  // namespace cobble_chromium
