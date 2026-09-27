// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/ui/cobble/cobble_extensions.h"
#include "chrome/browser/ui/cobble/cobble_identity.h"
#include "chrome/browser/ui/cobble/cobble_local_file.h"
#include "chrome/browser/ui/cobble/cobble_devtools.h"
#include "chrome/browser/ui/cobble/cobble_prompts.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <cctype>
#include <cstring>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/check.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/files/file_path.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/uuid.h"
#include "chrome/browser/chrome_browser_main_extra_parts.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/application_lifetime.h"
#include "chrome/browser/lifetime/browser_shutdown.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/permissions/system/system_media_capture_permissions_mac.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_destroyer.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_tabstrip.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/create_browser_window.h"
#include "chrome/browser/ui/cobble/cobble_profile_deletion.h"
#include "chrome/browser/ui/tabs/tab_enums.h"
#include "chrome/browser/ui/tabs/tab_model.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/common/pref_names.h"
#include "components/autofill/core/common/autofill_prefs.h"
#include "components/history/core/common/pref_names.h"
#include "components/keep_alive_registry/keep_alive_registry.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/password_manager/core/common/password_manager_pref_names.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/permission_controller.h"
#include "content/public/browser/permission_descriptor_util.h"
#include "content/public/browser/render_frame_host.h"
#include "components/security_state/content/content_utils.h"
#include "components/security_state/core/security_state.h"
#include "net/cert/cert_status_flags.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/media_stream_request.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/content_switches.h"
#include "media/base/media_switches.h"
#include "services/network/public/cpp/is_potentially_trustworthy.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"
#include "ui/base/page_transition_types.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "url/gurl.h"

namespace {
using MediaResult = blink::mojom::MediaStreamRequestResult;
}

struct CCSContext {
  raw_ptr<Profile> profile = nullptr;
  bool isolated_private = false;
  std::unique_ptr<ScopedProfileKeepAlive> original_profile_keep_alive;
};

struct BrowserEntry {
  raw_ptr<Browser> browser = nullptr;
  raw_ptr<BrowserWindow> window = nullptr;
  std::string host_window_id;
};

struct PrivateProfileEntry {
  std::string key;
  raw_ptr<Profile> profile = nullptr;
  size_t leases = 0;
};

struct PendingContextOpen {
  raw_ptr<void> callback_data = nullptr;
  CCSContextOpenedCallback callback = nullptr;
  std::string private_key;
  base::FilePath profile_path;
  bool completed_for_shutdown = false;

  void* TakeCallbackData() {
    // The client may free its request while handling the completion callback.
    // Release our tracked borrow before transferring control back to it.
    void* data = callback_data.get();
    callback_data = nullptr;
    return data;
  }
};

struct BridgeState;

struct CCSPage final : public content::WebContentsObserver,
                       public MediaStreamCaptureIndicator::Observer,
                       public find_in_page::FindResultObserver,
                       public favicon::FaviconDriverObserver {
  CCSPage(Browser* owner, content::WebContents* contents,
          std::string host_window_id);
  ~CCSPage() override;

  void SendState();
  void SendVisit(const std::string& url, const std::string& title);
  void FlushPendingVisit(const std::string& title);
  void DidStartNavigation(content::NavigationHandle* handle) override;
  void DidFinishNavigation(content::NavigationHandle* handle) override;
  void RenderFrameDeleted(content::RenderFrameHost* frame) override;
  void DidChangeVisibleSecurityState() override;
  void DidStopLoading() override;
  void TitleWasSet(content::NavigationEntry* entry) override;
  void OnAudioStateChanged(bool) override;
  void DidUpdateAudioMutingState(bool) override;
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override;
  void BeforeUnloadFired(bool proceed) override;
  void DidOpenRequestedURL(content::WebContents* new_contents,
                           content::RenderFrameHost* source_render_frame_host,
                           const GURL& url,
                           const content::Referrer& referrer,
                           WindowOpenDisposition disposition,
                           ui::PageTransition transition,
                           bool started_from_context_menu,
                           bool renderer_initiated) override;
  void WebContentsDestroyed() override;
  void OnFindResultAvailable(content::WebContents* contents) override;
  void OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) override;
  void OnIsCapturingVideoChanged(content::WebContents* contents,
                                 bool capturing) override;
  void OnIsCapturingAudioChanged(content::WebContents* contents,
                                 bool capturing) override;
  void OnFaviconUpdated(favicon::FaviconDriver* driver,
                        NotificationIconType icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override;
  void RetireBridge();

  raw_ptr<Browser> browser = nullptr;
  std::string host_window_id;
  bool crashed = false;
  bool closed = false;
  bool close_requested = false;
  bool moving_hosts = false;
  bool released = false;
  bool notifying_closed = false;
  raw_ptr<find_in_page::FindTabHelper> find_helper = nullptr;
  raw_ptr<favicon::ContentFaviconDriver> favicon_driver = nullptr;
  std::vector<uint8_t> favicon_png;
  std::string hovered_link;
  std::optional<std::string> pending_cross_document_visit;
  base::WeakPtrFactory<CCSPage> weak_factory{this};
};

struct CCSMediaPermissionRequest {
  uint64_t id = 0;
  base::WeakPtr<CCSPage> page;
  content::GlobalRenderFrameHostToken frame_token;
  content::GlobalRenderFrameHostId frame_id;
  content::MediaStreamRequest request;
  content::MediaResponseCallback callback;
  std::string requesting_origin;
  std::string embedding_origin;
  std::string frame_token_string;
  uint32_t kinds = 0;
  bool resolved = false;

  CCSMediaPermissionRequest(uint64_t request_id,
                            base::WeakPtr<CCSPage> request_page,
                            content::RenderFrameHost* frame,
                            const content::MediaStreamRequest& media_request,
                            content::MediaResponseCallback media_callback);
};

struct PendingPopup final : public content::WebContentsObserver {
  PendingPopup(base::WeakPtr<CCSPage> opener, content::WebContents* contents)
      : content::WebContentsObserver(contents), opener(std::move(opener)) {}
  void StopObserving() { Observe(nullptr); }
  void WebContentsDestroyed() override;

  base::WeakPtr<CCSPage> opener;
  base::WeakPtrFactory<PendingPopup> weak_factory{this};
};

struct BridgeState {
  CCSClientV12 client = {};
  bool enabled = false;
  bool ui_ready_sent = false;
  bool browser_started = false;
  bool ready_sent = false;
  bool stopping = false;
  bool quit_deferred = false;
  bool quit_resumed = false;
  raw_ptr<Profile> initial_profile = nullptr;
  std::unique_ptr<ScopedProfileKeepAlive> initial_profile_keep_alive;
  std::vector<BrowserEntry> browsers;
  std::vector<CCSPage*> pages;
  std::vector<CCSContext*> contexts;
  std::vector<std::unique_ptr<PendingPopup>> pending_popups;
  std::vector<std::unique_ptr<CCSMediaPermissionRequest>> media_requests;
  uint64_t next_media_request_id = 1;
  uint64_t next_prompt_request_id = 1;
  std::vector<PrivateProfileEntry> private_profiles;
  std::vector<PendingContextOpen*> pending_context_opens;
  std::vector<void (*)()> shutdown_callbacks;
};

CCSMediaPermissionRequest::CCSMediaPermissionRequest(
    uint64_t request_id,
    base::WeakPtr<CCSPage> request_page,
    content::RenderFrameHost* frame,
    const content::MediaStreamRequest& media_request,
    content::MediaResponseCallback media_callback)
    : id(request_id),
      page(std::move(request_page)),
      frame_token(frame->GetGlobalFrameToken()),
      frame_id(frame->GetGlobalId()),
      request(media_request),
      callback(std::move(media_callback)),
      requesting_origin(media_request.url_origin.Serialize()),
      embedding_origin(frame->GetMainFrame()->GetLastCommittedOrigin().Serialize()),
      frame_token_string(frame_token.frame_token.value().ToString()) {
  if (request.audio_type ==
      blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE) {
    kinds |= CCS_MEDIA_PERMISSION_MICROPHONE;
  }
  if (request.video_type ==
      blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE) {
    kinds |= CCS_MEDIA_PERMISSION_CAMERA;
  }
}

namespace {

std::string& PendingHostWindowID() {
  static base::NoDestructor<std::string> value;
  return *value;
}

std::string CanonicalHostWindowID(const char* value) {
  if (!value) {
    return {};
  }
  return base::Uuid::ParseCaseInsensitive(value).AsLowercaseString();
}

BridgeState& State() {
  // Chromium intentionally leaks process-wide registries at shutdown.
  static BridgeState* state = new BridgeState();
  return *state;
}

bool ShutdownDiagnosticsEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(
      "cobble-shutdown-diagnostics");
}

void LogShutdownDiagnostics(const char* phase) {
  if (!ShutdownDiagnosticsEnabled()) {
    return;
  }
  BridgeState& state = State();
  LOG(ERROR) << "Cobble shutdown " << phase
             << " stopping=" << state.stopping
             << " ready=" << state.ready_sent
             << " quit_deferred=" << state.quit_deferred
             << " quit_resumed=" << state.quit_resumed
             << " browsers=" << state.browsers.size()
             << " pages=" << state.pages.size()
             << " contexts=" << state.contexts.size()
             << " popups=" << state.pending_popups.size()
             << " media=" << state.media_requests.size()
             << " profile_opens=" << state.pending_context_opens.size()
             << " trying_to_quit=" << browser_shutdown::IsTryingToQuit()
             << " keep_alive=" << *KeepAliveRegistry::GetInstance();
  for (const BrowserEntry& entry : state.browsers) {
    UnloadController* unload = UnloadController::From(entry.browser.get());
    LOG(ERROR) << "Cobble shutdown browser phase=" << phase
               << " host=" << entry.host_window_id
               << " tabs=" << entry.browser->tab_strip_model()->count()
               << " attempting=" << unload->is_attempting_to_close_browser()
               << " delete_scheduled=" << unload->is_delete_scheduled();
  }
}

void CheckUIThread() {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

CCSPage* FindPage(content::WebContents* contents) {
  if (!contents) {
    return nullptr;
  }
  for (CCSPage* page : State().pages) {
    if (!page->closed && page->web_contents() == contents) {
      return page;
    }
  }
  return nullptr;
}

CCSMediaPermissionRequest* FindMediaRequest(uint64_t id) {
  for (const auto& request : State().media_requests) {
    if (request->id == id) {
      return request.get();
    }
  }
  return nullptr;
}

CCSMediaPermissionRequest* FindMediaRequest(
    CCSMediaPermissionRequestRef request) {
  for (const auto& candidate : State().media_requests) {
    if (candidate.get() == request) {
      return candidate.get();
    }
  }
  return nullptr;
}

bool PageHasPendingMediaRequest(CCSPage* page) {
  return std::ranges::any_of(State().media_requests,
                             [page](const auto& request) {
    return request->page.get() == page;
  });
}

bool MediaRequestIsLive(const CCSMediaPermissionRequest& request) {
  content::RenderFrameHost* frame =
      content::RenderFrameHost::FromFrameToken(request.frame_token);
  return request.page &&
         cobble_chromium::PageAcceptsPromptResult(
             request.page.get(), request.page->web_contents()) && frame &&
         frame == content::RenderFrameHost::FromID(request.frame_id) &&
         content::WebContents::FromRenderFrameHost(frame) ==
             request.page->web_contents() &&
         frame->GetLastCommittedOrigin() == request.request.url_origin &&
         frame->GetMainFrame()->GetLastCommittedOrigin().Serialize() ==
             request.embedding_origin;
}

void FinishMediaRequest(uint64_t id,
                        MediaResult result,
                        const blink::mojom::StreamDevicesSet& devices,
                        bool notify_cancelled = false) {
  auto& requests = State().media_requests;
  auto actual = std::find_if(requests.begin(), requests.end(),
                             [id](const auto& item) { return item->id == id; });
  if (actual == requests.end()) {
    return;
  }
  std::unique_ptr<CCSMediaPermissionRequest> request = std::move(*actual);
  requests.erase(actual);
  if (request->page) {
    request->page->SendState();
  }
  if (notify_cancelled && !request->resolved &&
      State().client.media_permission_cancelled) {
    request->resolved = true;
    State().client.media_permission_cancelled(State().client.user_data,
                                              request.get(), request->id);
  }
  if (notify_cancelled && result == MediaResult::OK) {
    result = MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER;
  }
  if (result == MediaResult::OK && !MediaRequestIsLive(*request)) {
    const blink::mojom::StreamDevicesSet no_devices;
    std::move(request->callback)
        .Run(no_devices, MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER, nullptr);
    return;
  }
  std::unique_ptr<content::MediaStreamUI> ui;
  if (result == MediaResult::OK && request->page &&
      !devices.stream_devices.empty()) {
    ui = MediaCaptureDevicesDispatcher::GetInstance()
             ->GetMediaStreamCaptureIndicator()
             ->RegisterMediaStream(request->page->web_contents(),
                                   *devices.stream_devices.front());
  }
  std::move(request->callback).Run(devices, result, std::move(ui));
}

void FinishMediaRequest(uint64_t id,
                        MediaResult result,
                        bool notify_cancelled = false) {
  const blink::mojom::StreamDevicesSet devices;
  FinishMediaRequest(id, result, devices, notify_cancelled);
}

void ContinueAllowedMediaRequest(uint64_t id) {
  CCSMediaPermissionRequest* pending = FindMediaRequest(id);
  if (!pending || !MediaRequestIsLive(*pending)) {
    if (pending) {
      FinishMediaRequest(id, MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER);
    }
    return;
  }
  using system_permission_settings::SystemPermission;
  const bool fake_devices = base::CommandLine::ForCurrentProcess()->HasSwitch(
      switches::kUseFakeDeviceForMediaStream);
  if (!fake_devices &&
      (pending->kinds & CCS_MEDIA_PERMISSION_MICROPHONE)) {
    const SystemPermission status =
        system_permission_settings::CheckSystemAudioCapturePermission();
    if (status == SystemPermission::kNotDetermined) {
      system_permission_settings::RequestSystemAudioCapturePermission(
          base::BindOnce(&ContinueAllowedMediaRequest, id));
      return;
    }
    if (status != SystemPermission::kAllowed) {
      FinishMediaRequest(id, MediaResult::PERMISSION_DENIED_BY_SYSTEM);
      return;
    }
  }
  if (!fake_devices && (pending->kinds & CCS_MEDIA_PERMISSION_CAMERA)) {
    const SystemPermission status =
        system_permission_settings::CheckSystemVideoCapturePermission();
    if (status == SystemPermission::kNotDetermined) {
      system_permission_settings::RequestSystemVideoCapturePermission(
          base::BindOnce(&ContinueAllowedMediaRequest, id));
      return;
    }
    if (status != SystemPermission::kAllowed) {
      FinishMediaRequest(id, MediaResult::PERMISSION_DENIED_BY_SYSTEM);
      return;
    }
  }

  auto* dispatcher = MediaCaptureDevicesDispatcher::GetInstance();
  auto stream = blink::mojom::StreamDevices::New();
  if (pending->kinds & CCS_MEDIA_PERMISSION_MICROPHONE) {
    stream->audio_device = dispatcher->GetPreferredAudioDeviceForBrowserContext(
        pending->page->web_contents()->GetBrowserContext(),
        pending->request.requested_audio_device_ids);
    if (!stream->audio_device) {
      FinishMediaRequest(id, MediaResult::NO_HARDWARE);
      return;
    }
  }
  if (pending->kinds & CCS_MEDIA_PERMISSION_CAMERA) {
    stream->video_device = dispatcher->GetPreferredVideoDeviceForBrowserContext(
        pending->page->web_contents()->GetBrowserContext(),
        pending->request.requested_video_device_ids);
    if (!stream->video_device) {
      FinishMediaRequest(id, MediaResult::NO_HARDWARE);
      return;
    }
  }
  blink::mojom::StreamDevicesSet devices;
  devices.stream_devices.push_back(std::move(stream));
  FinishMediaRequest(id, MediaResult::OK, devices);
}

void CancelMediaRequestsForPage(CCSPage* page) {
  std::vector<uint64_t> ids;
  for (const auto& request : State().media_requests) {
    if (request->page.get() == page) {
      ids.push_back(request->id);
    }
  }
  for (uint64_t id : ids) {
    FinishMediaRequest(id, MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER,
                       /*notify_cancelled=*/true);
  }
}

BrowserEntry* EntryForBrowser(Browser* browser) {
  for (BrowserEntry& entry : State().browsers) {
    if (entry.browser == browser) {
      return &entry;
    }
  }
  return nullptr;
}

Browser* BrowserForPage(CCSPage* page) {
  if (!page || page->closed || !page->web_contents()) {
    return nullptr;
  }
  if (page->browser) {
    const int index = page->browser->tab_strip_model()->GetIndexOfWebContents(
        page->web_contents());
    if (index != TabStripModel::kNoTab) {
      return page->browser;
    }
  }
  for (const BrowserEntry& entry : State().browsers) {
    if (entry.browser->tab_strip_model()->GetIndexOfWebContents(
            page->web_contents()) != TabStripModel::kNoTab) {
      page->browser = entry.browser;
      return entry.browser;
    }
  }
  return nullptr;
}

CCSPage* WrapPage(Browser* browser, content::WebContents* contents) {
  if (!contents) {
    return nullptr;
  }
  if (CCSPage* existing = FindPage(contents)) {
    return existing;
  }
  if (!browser) {
    for (const BrowserEntry& candidate : State().browsers) {
      if (candidate.browser->tab_strip_model()->GetIndexOfWebContents(contents) !=
          TabStripModel::kNoTab) {
        browser = candidate.browser;
        break;
      }
    }
  }
  BrowserEntry* entry = browser ? EntryForBrowser(browser) : nullptr;
  CCSPage* page = new CCSPage(
      browser, contents,
      entry ? entry->host_window_id
            : base::Uuid::GenerateRandomV4().AsLowercaseString());
  State().pages.push_back(page);
  // page_create returns before the first callback so clients can install the
  // opaque-handle mapping. This also gives popup clients time to wrap the view.
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce([](base::WeakPtr<CCSPage> candidate) {
        if (candidate) {
          candidate->SendState();
        }
      }, page->weak_factory.GetWeakPtr()));
  return page;
}

void DeliverPendingPopup(base::WeakPtr<CCSPage> opener,
                         base::WeakPtr<CCSPage> popup) {
  if (!popup) {
    return;
  }
  const bool opener_is_live = opener && !opener->closed && !opener->released;
  if (!State().stopping && !popup->closed && opener_is_live &&
      State().client.popup_created) {
    popup->released = false;
    State().client.popup_created(State().client.user_data, opener.get(),
                                 popup.get(),
                                 popup->host_window_id.c_str());
    if (popup) {
      popup->SendState();
    }
  } else if (!popup->closed) {
    CCSPageForceClose(popup.get());
  }
}

void MaybeSendReady() {
  BridgeState& state = State();
  if (!state.ready_sent && state.browser_started && state.initial_profile) {
    state.ready_sent = true;
    if (state.client.runtime_ready) {
      state.client.runtime_ready(state.client.user_data);
    }
  }
}

void SendUIReady() {
  BridgeState& state = State();
  if (!state.ui_ready_sent) {
    state.ui_ready_sent = true;
    if (state.client.runtime_ui_ready) {
      state.client.runtime_ui_ready(state.client.user_data);
    }
  }
}

bool IsValidContextKey(const std::string& key) {
  if (key.empty() || key.size() > 64) {
    return false;
  }
  for (unsigned char c : key) {
    if (!std::isalnum(c) && c != '-' && c != '_' && c != '.') {
      return false;
    }
  }
  return true;
}

void ConfigureProfileForHost(Profile* profile) {
  CHECK(profile);
  PrefService* preferences = profile->GetOriginalProfile()->GetPrefs();
  preferences->SetBoolean(prefs::kSavingBrowserHistoryDisabled, true);
  preferences->SetBoolean(prefs::kPromptForDownload, true);
  preferences->SetBoolean(password_manager::prefs::kCredentialsEnableService,
                          false);
  preferences->SetBoolean(
      password_manager::prefs::kCredentialsEnableAutosignin, false);
  preferences->SetBoolean(autofill::prefs::kAutofillProfileEnabled, false);
  preferences->SetBoolean(autofill::prefs::kAutofillCreditCardEnabled, false);
}

void FinishContextOpen(std::string private_key,
                       void* callback_data,
                       CCSContextOpenedCallback callback,
                       Profile* original) {
  if (!original) {
    callback(callback_data, nullptr, "Chromium profile initialization failed");
    return;
  }
  auto profile_keep_alive = ScopedProfileKeepAlive::TryAcquire(
      original, ProfileKeepAliveOrigin::kAppWindow);
  if (!profile_keep_alive) {
    callback(callback_data, nullptr,
             "Chromium profile is already shutting down");
    return;
  }
  g_browser_process->profile_manager()->ClearFirstBrowserWindowKeepAlive(
      original);
  ConfigureProfileForHost(original);
  Profile* selected = original;
  bool isolated_private = false;
  if (!private_key.empty()) {
    const std::string scoped_key =
        original->GetPath().AsUTF8Unsafe() + "\n" + private_key;
    auto found = std::find_if(
        State().private_profiles.begin(), State().private_profiles.end(),
        [&scoped_key](const auto& item) { return item.key == scoped_key; });
    if (found != State().private_profiles.end()) {
      selected = found->profile;
      ++found->leases;
    } else {
      selected = original->GetOffTheRecordProfile(
          Profile::OTRProfileID::CreateUnique("Cobble::PrivateWindow"),
          /*create_if_needed=*/true);
      State().private_profiles.push_back({scoped_key, selected, 1});
    }
    isolated_private = true;
  }
  auto* context = new CCSContext{selected, isolated_private,
                                 std::move(profile_keep_alive)};
  State().contexts.push_back(context);
  callback(callback_data, context, nullptr);
}

void FinishPendingContextOpen(PendingContextOpen* pending, Profile* profile) {
  auto& requests = State().pending_context_opens;
  std::erase(requests, pending);
  if (!pending->completed_for_shutdown) {
    void* callback_data = pending->TakeCallbackData();
    if (State().stopping) {
      pending->callback(callback_data, nullptr,
                        "Chromium runtime is stopping");
    } else {
      FinishContextOpen(pending->private_key, callback_data, pending->callback,
                        profile);
    }
  }
  delete pending;
}

void ReleasePrivateProfileLeaseInternal(Profile* profile) {
  auto& profiles = State().private_profiles;
  auto found = std::find_if(profiles.begin(), profiles.end(),
                            [profile](const auto& item) {
                              return item.profile == profile;
                            });
  if (found == profiles.end()) {
    return;
  }
  CHECK_GT(found->leases, 0u);
  if (--found->leases != 0) {
    return;
  }
  profiles.erase(found);
  ProfileDestroyer::DestroyOTRProfileWhenAppropriate(profile);
}

class CobbleMainExtraParts final : public ChromeBrowserMainExtraParts {
 public:
  void PostCreateThreads() override {
    SendUIReady();
  }

  void PostProfileInit(Profile* profile, bool is_initial_profile) override {
    ConfigureProfileForHost(profile);
    if (is_initial_profile) {
      State().initial_profile_keep_alive = ScopedProfileKeepAlive::TryAcquire(
          profile, ProfileKeepAliveOrigin::kAppWindow);
      CHECK(State().initial_profile_keep_alive);
      g_browser_process->profile_manager()->ClearFirstBrowserWindowKeepAlive(
          profile);
      State().initial_profile = profile;
      MaybeSendReady();
    }
  }

  void PostBrowserStart() override {
    State().browser_started = true;
    MaybeSendReady();
  }

  void PostMainMessageLoopRun() override {
    BridgeState& state = State();
    state.stopping = true;
    for (CCSContext* context : state.contexts) {
      cobble_chromium::ClearContextIdentityPolicy(context);
    }
    auto shutdown_callbacks = std::move(state.shutdown_callbacks);
    for (auto callback : shutdown_callbacks) {
      callback();
    }
    for (PendingContextOpen* pending : state.pending_context_opens) {
      if (!pending->completed_for_shutdown) {
        pending->completed_for_shutdown = true;
        pending->callback(pending->TakeCallbackData(), nullptr,
                          "Chromium runtime stopped before profile opened");
      }
    }
    while (!state.media_requests.empty()) {
      FinishMediaRequest(state.media_requests.front()->id,
                         MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER,
                         /*notify_cancelled=*/true);
    }
    if (state.client.runtime_will_stop) {
      state.client.runtime_will_stop(state.client.user_data);
    }
    state.ui_ready_sent = false;
    state.ready_sent = false;
    state.browser_started = false;
    state.initial_profile = nullptr;
    state.initial_profile_keep_alive.reset();
    state.browsers.clear();
    state.pending_popups.clear();
    state.private_profiles.clear();
  }
};

}  // namespace

void PendingPopup::WebContentsDestroyed() {
  Observe(nullptr);
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce([](base::WeakPtr<PendingPopup> destroyed) {
        if (!destroyed) {
          return;
        }
        std::erase_if(State().pending_popups,
                      [&destroyed](const auto& pending) {
                        return pending.get() == destroyed.get();
                      });
      }, weak_factory.GetWeakPtr()));
}

CCSPage::CCSPage(Browser* owner,
                 content::WebContents* contents,
                 std::string owner_host_window_id)
    : content::WebContentsObserver(contents),
      browser(owner),
      host_window_id(std::move(owner_host_window_id)),
      find_helper(find_in_page::FindTabHelper::FromWebContents(contents)),
      favicon_driver(favicon::ContentFaviconDriver::FromWebContents(contents)) {
  if (find_helper) {
    find_helper->AddObserver(this);
  }
  if (favicon_driver) {
    favicon_driver->AddObserver(this);
  }
  MediaCaptureDevicesDispatcher::GetInstance()
      ->GetMediaStreamCaptureIndicator()
      ->AddObserver(this);
}

CCSPage::~CCSPage() {
  MediaCaptureDevicesDispatcher::GetInstance()
      ->GetMediaStreamCaptureIndicator()
      ->RemoveObserver(this);
  if (find_helper) {
    find_helper->RemoveObserver(this);
  }
  if (favicon_driver) {
    favicon_driver->RemoveObserver(this);
  }
  Observe(nullptr);
  auto& pages = State().pages;
  std::erase(pages, this);
}

void CCSPage::SendState() {
  if (released || closed || !web_contents() ||
      !State().client.page_state_changed) {
    return;
  }
  const std::string url = web_contents()->GetVisibleURL().spec();
  const std::string title = base::UTF16ToUTF8(web_contents()->GetTitle());
  content::NavigationController& controller = web_contents()->GetController();
  CCSPageConnection connection = CCS_PAGE_CONNECTION_UNKNOWN;
  bool security_error_page = false;
  bool security_certificate_error = false;
  bool security_displayed_mixed_content = false;
  bool security_ran_mixed_content = false;
  const GURL visible_url = web_contents()->GetVisibleURL();
  std::unique_ptr<security_state::VisibleSecurityState> security =
      security_state::GetVisibleSecurityState(web_contents());
  if (!crashed && security && security->url == visible_url) {
    const security_state::SecurityLevel level =
        security_state::GetSecurityLevel(*security);
    security_error_page = security->is_error_page;
    security_certificate_error = net::IsCertStatusError(security->cert_status);
    security_displayed_mixed_content =
        security->displayed_mixed_content ||
        security->displayed_content_with_cert_errors ||
        security->contained_mixed_form;
    security_ran_mixed_content =
        security->ran_mixed_content || security->ran_content_with_cert_errors;
    if (visible_url.SchemeIsHTTPOrHTTPS()) {
      if (security_error_page || security_certificate_error) {
        connection = CCS_PAGE_CONNECTION_INSECURE;
      } else if (security_displayed_mixed_content || security_ran_mixed_content) {
        connection = CCS_PAGE_CONNECTION_MIXED;
      } else if (!security->connection_info_initialized) {
        connection = CCS_PAGE_CONNECTION_UNKNOWN;
      } else if (level == security_state::SECURE) {
        connection = CCS_PAGE_CONNECTION_SECURE;
      } else {
        connection = CCS_PAGE_CONNECTION_INSECURE;
      }
    } else {
      connection = CCS_PAGE_CONNECTION_EMPTY;
    }
  }
  auto indicator = MediaCaptureDevicesDispatcher::GetInstance()
                       ->GetMediaStreamCaptureIndicator();
  const bool has_pending_prompt = PageHasPendingMediaRequest(this) ||
                       cobble_chromium::PageHasPendingPrompt(web_contents());
  const CCSPageStateV4 page_state = {
      .struct_size = sizeof(CCSPageStateV4),
      .url_utf8 = url.c_str(),
      .title_utf8 = title.c_str(),
      .loading = static_cast<uint8_t>(web_contents()->IsLoading()),
      .can_go_back = static_cast<uint8_t>(
          controller.CanGoBack() &&
          cobble_chromium::CanNavigateLocalFileHistory(this, -1)),
      .can_go_forward = static_cast<uint8_t>(
          controller.CanGoForward() &&
          cobble_chromium::CanNavigateLocalFileHistory(this, 1)),
      .crashed = static_cast<uint8_t>(crashed),
      .audible = static_cast<uint8_t>(
          !crashed && web_contents()->IsCurrentlyAudible()),
      .audio_muted = static_cast<uint8_t>(web_contents()->IsAudioMuted()),
      .connection = connection,
      .security_error_page = static_cast<uint8_t>(security_error_page),
      .security_certificate_error =
          static_cast<uint8_t>(security_certificate_error),
      .security_displayed_mixed_content =
          static_cast<uint8_t>(security_displayed_mixed_content),
      .security_ran_mixed_content =
          static_cast<uint8_t>(security_ran_mixed_content),
      .capturing_microphone = static_cast<uint8_t>(
          !crashed && indicator->IsCapturingAudio(web_contents())),
      .capturing_camera = static_cast<uint8_t>(
          !crashed && indicator->IsCapturingVideo(web_contents())),
      .favicon_png = favicon_png.empty() ? nullptr : favicon_png.data(),
      .favicon_png_size = favicon_png.size(),
      .hovered_link_utf8 = hovered_link.empty() ? nullptr : hovered_link.c_str(),
      .has_pending_prompt = static_cast<uint8_t>(has_pending_prompt),
  };
  State().client.page_state_changed(State().client.user_data, this,
                                    &page_state);
}

void CCSPage::SendVisit(const std::string& url, const std::string& title) {
  if (released || closed || !web_contents() ||
      !State().client.page_navigation_committed) {
    return;
  }
  State().client.page_navigation_committed(
      State().client.user_data, this, url.c_str(), title.c_str());
}

void CCSPage::FlushPendingVisit(const std::string& title) {
  if (!pending_cross_document_visit) {
    return;
  }
  std::string url = std::move(*pending_cross_document_visit);
  pending_cross_document_visit.reset();
  SendVisit(url, title);
}

void CCSPage::DidStartNavigation(content::NavigationHandle* handle) {
  base::WeakPtr<CCSPage> local_file_alive = weak_factory.GetWeakPtr();
  cobble_chromium::LocalFileNavigationStarted(this, handle);
  if (!local_file_alive || closed || !web_contents()) {
    return;
  }
  if (!handle->IsSameDocument()) {
    base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
    CancelMediaRequestsForPage(this);
    if (!alive || closed || !web_contents()) {
      return;
    }
    cobble_chromium::CancelPagePrompts(web_contents(),
                                       handle->IsInPrimaryMainFrame());
    if (!alive || closed || !web_contents()) {
      return;
    }
  }
  if (handle->IsInPrimaryMainFrame()) {
    crashed = false;
    if (!handle->IsSameDocument()) {
      favicon_png.clear();
      hovered_link.clear();
      const std::string title =
          base::UTF16ToUTF8(web_contents()->GetTitle());
      base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
      FlushPendingVisit(title);
      if (!alive || closed || !web_contents()) {
        return;
      }
    }
    SendState();
  }
}

void CCSPage::DidFinishNavigation(content::NavigationHandle* handle) {
  if (!handle->IsInPrimaryMainFrame()) {
    return;
  }
  base::WeakPtr<CCSPage> local_file_alive = weak_factory.GetWeakPtr();
  cobble_chromium::LocalFileNavigationFinished(this, handle);
  if (!local_file_alive || closed || !web_contents()) {
    return;
  }
  const bool successful = handle->HasCommitted() && !handle->IsErrorPage();
  const bool same_document = successful && handle->IsSameDocument();
  const bool defer_cross_document =
      successful && !same_document && web_contents()->IsLoading();
  const std::string url = successful ? handle->GetURL().spec() : std::string();
  base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
  if (successful && !released && !closed &&
      State().client.page_primary_main_frame_committed) {
    State().client.page_primary_main_frame_committed(
        State().client.user_data, this, url.c_str());
    if (!alive || closed || !web_contents()) {
      return;
    }
  }
  std::optional<std::string> preceding_cross_document_visit;
  if (same_document) {
    preceding_cross_document_visit =
        std::move(pending_cross_document_visit);
    pending_cross_document_visit.reset();
  } else if (defer_cross_document) {
    pending_cross_document_visit = url;
  }

  const std::string title = base::UTF16ToUTF8(web_contents()->GetTitle());
  if (preceding_cross_document_visit) {
    SendVisit(*preceding_cross_document_visit, title);
    if (!alive || closed || !web_contents()) {
      return;
    }
  }
  if (successful && (same_document || !defer_cross_document)) {
    alive->SendVisit(url, title);
    if (!alive || closed || !web_contents()) {
      return;
    }
  }
  alive->SendState();
}

void CCSPage::RenderFrameDeleted(content::RenderFrameHost* frame) {
  base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
  CancelMediaRequestsForPage(this);
  if (!alive || closed || !web_contents()) {
    return;
  }
  cobble_chromium::CancelPagePrompts(web_contents(),
                                     frame->IsInPrimaryMainFrame());
}

void CCSPage::DidChangeVisibleSecurityState() {
  SendState();
}

void CCSPage::OnFindResultAvailable(content::WebContents* contents) {
  if (released || closed || contents != web_contents() || !find_helper ||
      !State().client.page_find_result) {
    return;
  }
  const find_in_page::FindNotificationDetails& native =
      find_helper->find_result();
  const CCSFindResultV1 result = {
      .struct_size = sizeof(CCSFindResultV1),
      .request_id = native.request_id(),
      .match_count = native.number_of_matches(),
      .active_match_ordinal = native.active_match_ordinal(),
      .final_update = static_cast<uint8_t>(native.final_update()),
  };
  State().client.page_find_result(State().client.user_data, this, &result);
}

void CCSPage::OnFindTabHelperDestroyed(find_in_page::FindTabHelper* helper) {
  if (find_helper == helper) {
    find_helper = nullptr;
  }
}

void CCSPage::OnIsCapturingVideoChanged(content::WebContents* contents, bool) {
  if (contents == web_contents()) {
    SendState();
  }
}

void CCSPage::OnIsCapturingAudioChanged(content::WebContents* contents, bool) {
  if (contents == web_contents()) {
    SendState();
  }
}

void CCSPage::OnFaviconUpdated(favicon::FaviconDriver*,
                               NotificationIconType icon_type,
                               const GURL& icon_url,
                               bool,
                               const gfx::Image& image) {
  // 16-dip-only ignored SVG and 32/192 PNG icons that never produce a
  // NON_TOUCH_16_DIP bitmap. Prefer the largest non-touch image; keep a
  // successful 16-dip icon if a later empty 16-dip notification arrives.
  if (icon_type != NON_TOUCH_16_DIP && icon_type != NON_TOUCH_LARGEST) {
    return;
  }
  std::vector<uint8_t> encoded;
  if (!icon_url.is_empty() && !image.IsEmpty()) {
    const SkBitmap bitmap = image.AsBitmap();
    if (bitmap.width() > 0 && bitmap.height() > 0 &&
        bitmap.width() <= 512 && bitmap.height() <= 512) {
      auto png = gfx::PNGCodec::EncodeBGRASkBitmap(
          bitmap, /*discard_transparency=*/false);
      if (png && png->size() <= 1024 * 1024) {
        encoded = std::move(*png);
      }
    }
  }
  if (encoded.empty() && !favicon_png.empty()) {
    return;
  }
  if (encoded != favicon_png) {
    favicon_png = std::move(encoded);
    SendState();
  }
}

void CCSPage::DidStopLoading() {
  std::optional<std::string> visit =
      std::move(pending_cross_document_visit);
  pending_cross_document_visit.reset();
  const std::string title = base::UTF16ToUTF8(web_contents()->GetTitle());
  base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
  if (visit) {
    SendVisit(*visit, title);
    if (!alive || closed || !web_contents()) {
      return;
    }
  }
  alive->SendState();
}

void CCSPage::TitleWasSet(content::NavigationEntry* entry) {
  SendState();
}

void CCSPage::OnAudioStateChanged(bool) {
  SendState();
}

void CCSPage::DidUpdateAudioMutingState(bool) {
  SendState();
}

void CCSPage::PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) {
  crashed = true;
  base::WeakPtr<CCSPage> local_file_alive = weak_factory.GetWeakPtr();
  cobble_chromium::LocalFileRenderProcessGone(this);
  if (!local_file_alive || closed || !web_contents()) {
    return;
  }
  base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
  cobble_chromium::CloseDevToolsForPage(this);
  if (!alive || closed || !web_contents()) {
    return;
  }
  favicon_png.clear();
  hovered_link.clear();
  cobble_chromium::CancelPageCaptures(web_contents());
  if (!alive || closed || !web_contents()) {
    return;
  }
  CancelMediaRequestsForPage(this);
  if (!alive || closed || !web_contents()) {
    return;
  }
  cobble_chromium::CancelPagePrompts(web_contents());
  if (!alive || closed || !web_contents()) {
    return;
  }
  const std::string title =
      web_contents() ? base::UTF16ToUTF8(web_contents()->GetTitle())
                     : std::string();
  FlushPendingVisit(title);
  if (!alive || closed || !web_contents()) {
    return;
  }
  SendState();
}

void CCSPage::BeforeUnloadFired(bool proceed) {
  if (!proceed) {
    base::WeakPtr<CCSPage> local_file_alive = weak_factory.GetWeakPtr();
    cobble_chromium::LocalFileBeforeUnloadCancelled(this);
    if (!local_file_alive) {
      return;
    }
  }
  if (proceed || !close_requested || closed) {
    return;
  }
  close_requested = false;
  if (!released && State().client.page_close_cancelled) {
    State().client.page_close_cancelled(State().client.user_data, this);
  }
}

void CCSPage::DidOpenRequestedURL(
    content::WebContents* new_contents,
    content::RenderFrameHost* source_render_frame_host,
    const GURL& url,
    const content::Referrer& referrer,
    WindowOpenDisposition disposition,
    ui::PageTransition transition,
    bool started_from_context_menu,
    bool renderer_initiated) {
  if (new_contents && !released && !closed) {
    State().pending_popups.push_back(
        std::make_unique<PendingPopup>(weak_factory.GetWeakPtr(), new_contents));
  }
}

void CCSPage::WebContentsDestroyed() {
  RetireBridge();
}

void CCSPage::RetireBridge() {
  if (closed) {
    return;
  }
  content::WebContents* retiring_contents = web_contents();
  Observe(nullptr);
  if (find_helper) {
    find_helper->RemoveObserver(this);
    find_helper = nullptr;
  }
  if (favicon_driver) {
    favicon_driver->RemoveObserver(this);
    favicon_driver = nullptr;
  }
  browser = nullptr;
  // Closing a page discards a commit whose load never reached a settled title.
  pending_cross_document_visit.reset();
  closed = true;
  close_requested = false;
  base::WeakPtr<CCSPage> alive = weak_factory.GetWeakPtr();
  cobble_chromium::CloseLocalFileForPage(this);
  if (!alive) {
    return;
  }
  cobble_chromium::CloseDevToolsForPage(this);
  if (!alive) {
    return;
  }
  cobble_chromium::CancelPageCaptures(retiring_contents);
  if (!alive) {
    return;
  }
  CancelMediaRequestsForPage(this);
  if (!alive) {
    return;
  }
  cobble_chromium::CancelPagePrompts(retiring_contents);
  if (!alive) {
    return;
  }
  if (!released && State().client.page_closed) {
    notifying_closed = true;
    State().client.page_closed(State().client.user_data, this);
    notifying_closed = false;
  }
  if (released) {
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                   this);
  }
}

extern "C" int32_t CCSSetClient(const CCSClientV12* client) {
  constexpr size_t kMinimumClientSize =
      offsetof(CCSClientV12, extension_install_cancelled) +
      sizeof(client->extension_install_cancelled);
  if (!client || client->abi_version != CCS_ABI_VERSION ||
      client->struct_size < kMinimumClientSize) {
    return -1;
  }
  BridgeState& state = State();
  if (state.browser_started) {
    return -2;
  }
  state.client = {};
  const size_t copy_size =
      std::min<size_t>(client->struct_size, sizeof(state.client));
  base::byte_span_from_ref(state.client)
      .first(copy_size)
      .copy_from(base::byte_span_from_ref(*client)
                     .first(copy_size));
  state.enabled = true;
  state.stopping = false;
  return 0;
}

extern "C" void CCSRequestQuit(uint8_t ignore_unload_handlers) {
  CheckUIThread();
  LogShutdownDiagnostics("before-request");
  State().quit_resumed = true;
  if (ignore_unload_handlers) {
    chrome::ExitIgnoreUnloadHandlers();
  } else {
    chrome::AttemptExit();
  }
  if (ShutdownDiagnosticsEnabled()) {
    LogShutdownDiagnostics("after-request");
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostDelayedTask(
        FROM_HERE,
        base::BindOnce(&LogShutdownDiagnostics, "one-second-after-request"),
        base::Seconds(1));
  }
}

extern "C" void CCSCancelQuit() {
  CheckUIThread();
  State().quit_deferred = false;
  State().quit_resumed = false;
}

extern "C" CCSContextRef CCSDefaultContext() {
  CheckUIThread();
  if (!State().ready_sent || !State().initial_profile) {
    return nullptr;
  }
  auto profile_keep_alive = ScopedProfileKeepAlive::TryAcquire(
      State().initial_profile, ProfileKeepAliveOrigin::kAppWindow);
  if (!profile_keep_alive) {
    return nullptr;
  }
  auto* context = new CCSContext{State().initial_profile, false,
                                 std::move(profile_keep_alive)};
  State().contexts.push_back(context);
  return context;
}

extern "C" CCSContextRef CCSPrivateContext() {
  CheckUIThread();
  if (!State().ready_sent || !State().initial_profile) {
    return nullptr;
  }
  auto profile_keep_alive = ScopedProfileKeepAlive::TryAcquire(
      State().initial_profile, ProfileKeepAliveOrigin::kAppWindow);
  if (!profile_keep_alive) {
    return nullptr;
  }
  Profile* profile =
      State().initial_profile->GetPrimaryOTRProfile(/*create_if_needed=*/true);
  auto found = std::find_if(State().private_profiles.begin(),
                            State().private_profiles.end(),
                            [profile](const auto& item) {
                              return item.profile == profile;
                            });
  if (found == State().private_profiles.end()) {
    State().private_profiles.push_back({"legacy-primary", profile, 1});
  } else {
    ++found->leases;
  }
  auto* context =
      new CCSContext{profile, true, std::move(profile_keep_alive)};
  State().contexts.push_back(context);
  return context;
}

extern "C" void CCSContextOpen(const char* profile_key_utf8,
                                const char* private_window_key_utf8,
                                void* callback_data,
                                CCSContextOpenedCallback callback) {
  CheckUIThread();
  if (!callback) {
    return;
  }
  if (!State().ready_sent || !State().initial_profile) {
    callback(callback_data, nullptr, "Chromium runtime is not ready");
    return;
  }
  const std::string profile_key = profile_key_utf8 ? profile_key_utf8 : "";
  const std::string private_key =
      private_window_key_utf8 ? private_window_key_utf8 : "";
  if ((!profile_key.empty() && !IsValidContextKey(profile_key)) ||
      (!private_key.empty() && !IsValidContextKey(private_key))) {
    callback(callback_data, nullptr,
             "Profile keys must be 1-64 ASCII letters, digits, '.', '_' or '-'");
    return;
  }
  if (profile_key.empty()) {
    FinishContextOpen(private_key, callback_data, callback,
                      State().initial_profile);
    return;
  }
  ProfileManager* manager = g_browser_process->profile_manager();
  const base::FilePath path =
      manager->user_data_dir().AppendASCII("Cobble-" + profile_key);
  if (cobble_chromium::IsProfileDeletionPending(path) ||
      IsProfileDirectoryMarkedForDeletion(path)) {
    callback(callback_data, nullptr,
             "Chromium profile deletion is pending or already committed");
    return;
  }
  if (Profile* loaded = manager->GetProfileByPath(path)) {
    FinishContextOpen(private_key, callback_data, callback, loaded);
    return;
  }
  auto* pending = new PendingContextOpen{
      callback_data, callback, private_key, path, false};
  State().pending_context_opens.push_back(pending);
  manager->CreateProfileAsync(
      path, base::BindOnce(&FinishPendingContextOpen, pending));
}

extern "C" void CCSContextRelease(CCSContextRef context) {
  CheckUIThread();
  if (!context || std::ranges::find(State().contexts, context) ==
                      State().contexts.end()) {
    return;
  }
  Profile* profile = context->profile;
  const bool isolated_private = context->isolated_private;
  cobble_chromium::ClearExtensionObservation(context);
  cobble_chromium::ClearContextIdentityPolicy(context);
  std::erase(State().contexts, context);
  delete context;
  if (isolated_private && !State().stopping) {
    // The final page_closed callback can precede Browser destruction. Defer
    // OTR teardown until the empty Browser has finished unwinding.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(&ReleasePrivateProfileLeaseInternal, profile));
  }
}

extern "C" CCSPageRef CCSPageCreate(CCSContextRef context,
                                      const char* host_window_id_utf8,
                                      const char* initial_url_utf8) {
  CheckUIThread();
  if (!State().ready_sent || State().stopping || !context ||
      !context->profile) {
    return nullptr;
  }
  GURL url(initial_url_utf8 ? initial_url_utf8 : "about:blank");
  if (!url.is_valid() || url.SchemeIsFile()) {
    return nullptr;
  }

  const std::string host_window_id =
      CanonicalHostWindowID(host_window_id_utf8);
  if (host_window_id.empty()) {
    return nullptr;
  }
  Browser* browser = nullptr;
  for (const BrowserEntry& entry : State().browsers) {
    if (!entry.browser->IsDeleteScheduled() &&
        entry.browser->GetProfile() == context->profile &&
        entry.host_window_id == host_window_id) {
      browser = entry.browser;
      break;
    }
  }
  if (!browser) {
    base::AutoReset<std::string> pending_host_window_id(
        &PendingHostWindowID(), host_window_id, std::string());
    BrowserWindowCreateParams params(context->profile,
                                     /*from_user_gesture=*/true);
    params.omit_from_session_restore = true;
    params.should_trigger_session_restore = false;
    browser = CreateBrowserWindow(std::move(params))->GetBrowserForMigrationOnly();
    if (!browser) {
      return nullptr;
    }
  }
  content::WebContents* contents = chrome::AddAndReturnTabAt(
      browser, GURL("about:blank"), -1, /*foreground=*/true);
  CCSPage* page = WrapPage(browser, contents);
  if (page) {
    cobble_chromium::AttachIdentityPolicy(context, contents);
    if (url != GURL("about:blank")) {
      contents->GetController().LoadURL(
          url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
    }
  }
  if (BrowserEntry* entry = EntryForBrowser(browser)) {
    entry->window->Show();
  }
  return page;
}

extern "C" void* CCSPageView(CCSPageRef page) {
  CheckUIThread();
  if (!page || page->closed || !page->web_contents()) {
    return nullptr;
  }
  return (__bridge void*)page->web_contents()
      ->GetNativeView()
      .GetNativeNSView();
}

extern "C" void CCSPageLoadURL(CCSPageRef page, const char* url_utf8) {
  CheckUIThread();
  if (!page || page->closed || !page->web_contents() || !url_utf8) {
    return;
  }
  GURL url(url_utf8);
  if (url.is_valid() && !url.SchemeIsFile()) {
    page->web_contents()->GetController().LoadURL(
        url, content::Referrer(), ui::PAGE_TRANSITION_TYPED, std::string());
  }
}

extern "C" void CCSPageGoBack(CCSPageRef page) {
  CheckUIThread();
  if (page && !page->closed && page->web_contents() &&
      page->web_contents()->GetController().CanGoBack() &&
      cobble_chromium::CanNavigateLocalFileHistory(page, -1)) {
    page->web_contents()->GetController().GoBack();
  }
}

extern "C" void CCSPageGoForward(CCSPageRef page) {
  CheckUIThread();
  if (page && !page->closed && page->web_contents() &&
      page->web_contents()->GetController().CanGoForward() &&
      cobble_chromium::CanNavigateLocalFileHistory(page, 1)) {
    page->web_contents()->GetController().GoForward();
  }
}

extern "C" uint8_t CCSPageReload(CCSPageRef page) {
  CheckUIThread();
  if (!page || page->closed || !page->web_contents()) {
    return 0;
  }
  if (cobble_chromium::IsLocalFileActive(page)) {
    // The client routes this through async openLocalFile so validation errors
    // remain visible and the old document survives a failed revalidation.
    return 0;
  }
  page->web_contents()->GetController().Reload(content::ReloadType::NORMAL,
                                                /*check_for_repost=*/true);
  return 1;
}

extern "C" uint8_t CCSMediaPermissionResolve(
    CCSMediaPermissionRequestRef request,
    uint8_t allow) {
  CheckUIThread();
  request = FindMediaRequest(request);
  if (!request || request->resolved || !MediaRequestIsLive(*request)) {
    return 0;
  }
  request->resolved = true;
  const uint64_t id = request->id;
  if (!allow) {
    FinishMediaRequest(id, MediaResult::PERMISSION_DENIED);
  } else {
    ContinueAllowedMediaRequest(id);
  }
  return 1;
}

extern "C" uint8_t CCSPageStopMediaCapture(CCSPageRef page) {
  CheckUIThread();
  if (!page || page->closed || !page->web_contents()) {
    return 0;
  }
  auto indicator = MediaCaptureDevicesDispatcher::GetInstance()
                       ->GetMediaStreamCaptureIndicator();
  if (!indicator->IsCapturingUserMedia(page->web_contents())) {
    return 0;
  }
  indicator->StopMediaCapturing(page->web_contents(),
                                MediaStreamCaptureIndicator::kUserMedia);
  return 1;
}

extern "C" void CCSPageStop(CCSPageRef page) {
  CheckUIThread();
  if (page && !page->closed && page->web_contents()) {
    page->web_contents()->Stop();
  }
}

extern "C" void CCSPageFocus(CCSPageRef page) {
  CheckUIThread();
  Browser* browser = BrowserForPage(page);
  if (!browser) {
    return;
  }
  const int index = browser->tab_strip_model()->GetIndexOfWebContents(
      page->web_contents());
  browser->tab_strip_model()->ActivateTabAt(index);
  page->web_contents()->Focus();
}

extern "C" void CCSPageSetVisible(CCSPageRef page, uint8_t visible) {
  CheckUIThread();
  if (!page || page->closed || !page->web_contents()) {
    return;
  }
  content::WebContents* contents = page->web_contents();
  const bool is_hidden =
      contents->GetVisibility() == content::Visibility::HIDDEN;
  if (visible && is_hidden) {
    contents->WasShown();
  } else if (!visible && !is_hidden) {
    contents->WasHidden();
  }
}

extern "C" uint8_t CCSPageMoveToHost(CCSPageRef page,
                                      const char* host_window_id_utf8) {
  CheckUIThread();
  Browser* source = BrowserForPage(page);
  if (State().stopping || !source || source->IsDeleteScheduled() ||
      page->close_requested) {
    return 0;
  }
  if (cobble_chromium::PageHasPendingPromptOrMedia(page)) {
    return 0;
  }
  const std::string host_window_id =
      CanonicalHostWindowID(host_window_id_utf8);
  if (host_window_id.empty()) {
    return 0;
  }
  if (BrowserEntry* source_entry = EntryForBrowser(source)) {
    page->host_window_id = source_entry->host_window_id;
  }
  if (page->host_window_id == host_window_id) {
    return 1;
  }
  const int index = source->tab_strip_model()->GetIndexOfWebContents(
      page->web_contents());
  if (index == TabStripModel::kNoTab ||
      source->tab_strip_model()->GetWebContentsAt(index) !=
          page->web_contents()) {
    return 0;
  }
  Browser* destination = nullptr;
  for (const BrowserEntry& entry : State().browsers) {
    if (!entry.browser->IsDeleteScheduled() &&
        entry.browser->GetProfile() == source->GetProfile() &&
        entry.host_window_id == host_window_id) {
      destination = entry.browser;
      break;
    }
  }
  if (!destination) {
    base::AutoReset<std::string> pending_host_window_id(
        &PendingHostWindowID(), host_window_id, std::string());
    BrowserWindowCreateParams params(source->GetProfile(),
                                     /*from_user_gesture=*/true);
    params.omit_from_session_restore = true;
    params.should_trigger_session_restore = false;
    destination =
        CreateBrowserWindow(std::move(params))->GetBrowserForMigrationOnly();
    if (!destination) {
      return 0;
    }
  }
  if (source->GetType() == destination->GetType()) {
    std::unique_ptr<tabs::TabModel> tab =
        source->tab_strip_model()->DetachTabAtForInsertion(index);
    CHECK(tab);
    base::AutoReset<bool> moving_hosts(&page->moving_hosts, true);
    destination->tab_strip_model()->InsertDetachedTabAt(
        destination->tab_strip_model()->count(), std::move(tab),
        AddTabTypes::ADD_ACTIVE);
  } else {
    std::unique_ptr<content::WebContents> contents =
        source->tab_strip_model()->DetachWebContentsAtForInsertion(index);
    CHECK(contents);
    CHECK_EQ(contents.get(), page->web_contents());
    base::AutoReset<bool> moving_hosts(&page->moving_hosts, true);
    destination->tab_strip_model()->AppendWebContents(std::move(contents), true);
  }
  page->browser = destination;
  page->host_window_id = host_window_id;
  return 1;
}

extern "C" void CCSPageClose(CCSPageRef page) {
  CheckUIThread();
  if (!page || page->closed) {
    return;
  }
  Browser* browser = BrowserForPage(page);
  if (!browser) {
    page->close_requested = false;
    if (page->released) {
      page->RetireBridge();
    } else if (State().client.page_close_cancelled) {
      State().client.page_close_cancelled(State().client.user_data, page);
    }
    return;
  }
  if (page->close_requested) {
    return;
  }
  const int index = browser->tab_strip_model()->GetIndexOfWebContents(
      page->web_contents());
  if (!browser->tab_strip_model()->IsTabClosable(
          browser->tab_strip_model()->GetTabAtIndex(index))) {
    if (!page->released && State().client.page_close_cancelled) {
      State().client.page_close_cancelled(State().client.user_data, page);
    }
    return;
  }
  page->close_requested = true;
  browser->tab_strip_model()->CloseWebContentsAt(
      index, CLOSE_USER_GESTURE | CLOSE_CREATE_HISTORICAL_TAB);
}

extern "C" void CCSPageForceClose(CCSPageRef page) {
  CheckUIThread();
  if (!page || page->closed) {
    return;
  }
  Browser* browser = BrowserForPage(page);
  if (!browser) {
    // The bridge does not own an unattached WebContents and cannot safely
    // delete it. Retire this handle synchronously so a forced client shutdown
    // cannot wait forever; its Chromium owner remains responsible for it.
    page->RetireBridge();
    return;
  }
  const int index = browser->tab_strip_model()->GetIndexOfWebContents(
      page->web_contents());
  browser->tab_strip_model()->DetachAndDeleteWebContentsAt(index);
}

extern "C" uint8_t CCSPageIsClosed(CCSPageRef page) {
  CheckUIThread();
  return static_cast<uint8_t>(!page || page->closed);
}

extern "C" void CCSPageRelease(CCSPageRef page) {
  CheckUIThread();
  if (!page ||
      std::ranges::find(State().pages, page) == State().pages.end()) {
    return;
  }
  if (!page->closed && page->web_contents()) {
    page->released = true;
    CCSPageClose(page);
    return;
  }
  if (page->notifying_closed) {
    page->released = true;
    return;
  }
  delete page;
}

namespace cobble_chromium {

bool IsEnabled() {
  return State().enabled;
}

bool IsStopping() {
  return State().stopping;
}

std::string& PendingHostWindowIDForDevTools() {
  return PendingHostWindowID();
}

const CCSClientV12& Client() {
  return State().client;
}

uint64_t NextPromptRequestID() {
  return State().next_prompt_request_id++;
}

bool HandleMediaAccessRequest(content::WebContents* contents,
                              const content::MediaStreamRequest& request,
                              content::MediaResponseCallback callback) {
  CheckUIThread();
  CCSPage* page = FindPage(contents);
  content::RenderFrameHost* frame = content::RenderFrameHost::FromID(
      request.render_process_id, request.render_frame_id);
  const bool audio = request.audio_type ==
                     blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE;
  const bool video = request.video_type ==
                     blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE;
  const bool unsupported_audio =
      request.audio_type != blink::mojom::MediaStreamType::NO_SERVICE && !audio;
  const bool unsupported_video =
      request.video_type != blink::mojom::MediaStreamType::NO_SERVICE && !video;
  if (!page || !frame || content::WebContents::FromRenderFrameHost(frame) != contents ||
      (!audio && !video) || unsupported_audio || unsupported_video ||
      frame->GetLastCommittedOrigin() != request.url_origin ||
      !network::IsUrlPotentiallyTrustworthy(request.security_origin)) {
    std::move(callback).Run({}, MediaResult::NOT_SUPPORTED, nullptr);
    return true;
  }

  content::PermissionController* permissions =
      contents->GetBrowserContext()->GetPermissionController();
  const auto denied = [permissions, frame](blink::PermissionType type) {
    return permissions->GetPermissionResultForCurrentDocument(
               content::PermissionDescriptorUtil::
                   CreatePermissionDescriptorForPermissionType(type),
               frame)
               .status == blink::mojom::PermissionStatus::DENIED;
  };
  if ((audio && denied(blink::PermissionType::AUDIO_CAPTURE)) ||
      (video && denied(blink::PermissionType::VIDEO_CAPTURE))) {
    std::move(callback).Run({}, MediaResult::PERMISSION_DENIED_BY_CONTROLLER,
                            nullptr);
    return true;
  }

  BridgeState& state = State();
  if (!state.client.media_permission_requested || state.stopping) {
    std::move(callback).Run({}, MediaResult::PERMISSION_DENIED, nullptr);
    return true;
  }
  auto pending = std::make_unique<CCSMediaPermissionRequest>(
      state.next_media_request_id++, page->weak_factory.GetWeakPtr(), frame,
      request, std::move(callback));
  CCSMediaPermissionRequest* handle = pending.get();
  const uint64_t request_id = handle->id;
  base::WeakPtr<CCSPage> live_page = page->weak_factory.GetWeakPtr();
  state.media_requests.push_back(std::move(pending));
  page->SendState();
  handle = FindMediaRequest(request_id);
  if (!live_page || !handle || !MediaRequestIsLive(*handle)) {
    if (handle) {
      FinishMediaRequest(request_id,
                         MediaResult::FAILED_DUE_TO_SHUTDOWN_OTHER);
    }
    return true;
  }
  const CCSMediaPermissionRequestV1 value = {
      .struct_size = sizeof(CCSMediaPermissionRequestV1),
      .request_id = handle->id,
      .kinds = handle->kinds,
      .requesting_origin_utf8 = handle->requesting_origin.c_str(),
      .embedding_origin_utf8 = handle->embedding_origin.c_str(),
      .frame_process_id = handle->frame_id.child_id.value(),
      .frame_routing_id = handle->frame_id.frame_routing_id,
      .frame_token_utf8 = handle->frame_token_string.c_str(),
      .user_gesture = static_cast<uint8_t>(request.user_gesture),
  };
  state.client.media_permission_requested(state.client.user_data,
                                          live_page.get(), handle, &value);
  return true;
}

bool ShouldAllowPopup(content::RenderFrameHost* opener,
                      const GURL& opener_url,
                      const GURL& top_level_url,
                      const url::Origin& source_origin,
                      const GURL& target_url,
                      int disposition,
                      bool user_gesture,
                      bool opener_suppressed) {
  CheckUIThread();
  BridgeState& state = State();
  content::WebContents* contents =
      opener ? content::WebContents::FromRenderFrameHost(opener) : nullptr;
  CCSPage* page = FindPage(contents);
  if (!page || state.stopping || !state.client.popup_requested ||
      opener->GetLastCommittedOrigin() != source_origin) {
    return false;
  }
  const std::string opener_value = opener_url.spec();
  const std::string top_value = top_level_url.spec();
  const std::string origin_value = source_origin.Serialize();
  const std::string target_value = target_url.spec();
  const CCSPopupRequestV1 request = {
      .struct_size = sizeof(CCSPopupRequestV1),
      .opener = page,
      .opener_url_utf8 = opener_value.c_str(),
      .top_level_url_utf8 = top_value.c_str(),
      .requesting_origin_utf8 = origin_value.c_str(),
      .target_url_utf8 = target_value.c_str(),
      .disposition = disposition,
      .user_gesture = static_cast<uint8_t>(user_gesture),
      .opener_suppressed = static_cast<uint8_t>(opener_suppressed),
  };
  return state.client.popup_requested(state.client.user_data, &request) != 0;
}

void RegisterShutdownCallback(void (*callback)()) {
  CheckUIThread();
  CHECK(callback);
  auto& callbacks = State().shutdown_callbacks;
  if (std::find(callbacks.begin(), callbacks.end(), callback) ==
      callbacks.end()) {
    callbacks.push_back(callback);
  }
}

std::unique_ptr<ChromeBrowserMainExtraParts> CreateMainExtraParts() {
  return std::make_unique<CobbleMainExtraParts>();
}

void RegisterBrowser(Browser* browser, BrowserWindow* window) {
  std::string host_window_id = PendingHostWindowID();
  if (host_window_id.empty()) {
    host_window_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  State().browsers.push_back({browser, window, std::move(host_window_id)});
}

void UnregisterBrowser(Browser* browser) {
  for (CCSPage* page : State().pages) {
    if (page->browser == browser) {
      page->browser = nullptr;
    }
  }
  std::erase_if(State().browsers,
                [browser](const BrowserEntry& entry) {
                  return entry.browser == browser;
                });
}

CCSPageRef PageForWebContents(content::WebContents* contents) {
  return FindPage(contents);
}

content::WebContents* PageWebContents(CCSPageRef page) {
  return page && !page->closed ? page->web_contents() : nullptr;
}

bool PageAcceptsPromptResult(CCSPageRef page,
                             content::WebContents* contents) {
  return !State().stopping && page && contents && FindPage(contents) == page &&
         !page->released && !page->closed && !page->close_requested &&
         page->web_contents() == contents;
}

bool PageHasPendingPromptOrMedia(CCSPageRef page) {
  content::WebContents* contents = PageWebContents(page);
  return contents && (PageHasPendingMediaRequest(page) ||
                      PageHasPendingPrompt(contents));
}

void* HostWindowForWebContents(content::WebContents* contents) {
  NSView* view = contents
                     ? contents->GetNativeView().GetNativeNSView()
                     : nil;
  if (view.window) {
    return (__bridge void*)view.window;
  }
  if (!State().client.host_window) {
    return nullptr;
  }
  CCSPage* page = FindPage(contents);
  Browser* browser = page ? BrowserForPage(page) : nullptr;
  if (!browser && contents) {
    for (const BrowserEntry& candidate : State().browsers) {
      if (candidate.browser->tab_strip_model()->GetIndexOfWebContents(contents) !=
          TabStripModel::kNoTab) {
        browser = candidate.browser;
        break;
      }
    }
  }
  const BrowserEntry* entry = browser ? EntryForBrowser(browser) : nullptr;
  const std::string& host_window_id =
      entry ? entry->host_window_id : page ? page->host_window_id
                                           : PendingHostWindowID();
  return State().client.host_window(State().client.user_data,
                                    host_window_id.c_str(), page);
}

void* HostWindowForBrowser(Browser* browser) {
  if (!browser || !State().client.host_window) {
    return nullptr;
  }
  const BrowserEntry* entry = EntryForBrowser(browser);
  const std::string& host_window_id =
      entry ? entry->host_window_id : PendingHostWindowID();
  return State().client.host_window(State().client.user_data,
                                    host_window_id.c_str(), nullptr);
}

void BrowserActiveTabChanged(content::WebContents* old_contents,
                             content::WebContents* new_contents) {
  if (CCSPage* page = FindPage(new_contents)) {
    page->SendState();
    if (!State().stopping && !page->released && !page->moving_hosts &&
        State().client.page_activated) {
      State().client.page_activated(State().client.user_data, page);
    }
  }
}

void BrowserPageStateChanged(content::WebContents* contents) {
  if (CCSPage* page = FindPage(contents)) {
    page->SendState();
  }
}

void BrowserTargetURLChanged(content::WebContents* contents, const GURL& url) {
  CheckUIThread();
  CCSPage* page = FindPage(contents);
  if (!page || page->closed) {
    return;
  }
  const std::string target = url.spec();
  const std::string bounded = target.size() <= 8192 ? target : std::string();
  if (page->hovered_link != bounded) {
    page->hovered_link = bounded;
    page->SendState();
  }
}

void BrowserTabStripChanged(Browser* browser) {
  if (!browser || State().stopping) {
    return;
  }
  auto& pending_popups = State().pending_popups;
  for (size_t index = 0; index < pending_popups.size();) {
    content::WebContents* contents = pending_popups[index]->web_contents();
    base::WeakPtr<CCSPage> opener = pending_popups[index]->opener;
    if (browser->tab_strip_model()->GetIndexOfWebContents(contents) ==
        TabStripModel::kNoTab) {
      ++index;
      continue;
    }
    pending_popups[index]->StopObserving();
    pending_popups.erase(pending_popups.begin() + index);
    CCSPage* popup = WrapPage(browser, contents);
    if (!popup) {
      continue;
    }
    // Client adoption can move the page, which must not mutate the tab strip
    // recursively from its insertion notification.
    popup->released = true;
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE,
        base::BindOnce(&DeliverPendingPopup, std::move(opener),
                       popup->weak_factory.GetWeakPtr()));
  }
}

Profile* ContextProfile(CCSContextRef context) {
  return context ? context->profile.get() : nullptr;
}

bool ResolveProfileKey(const char* key,
                       base::FilePath* path,
                       Profile** loaded_profile,
                       std::string* error) {
  if (!path || !loaded_profile || !error) {
    return false;
  }
  *loaded_profile = nullptr;
  const std::string value = key ? key : "";
  if (!IsValidContextKey(value)) {
    *error = value.empty()
                 ? "The default Chromium profile cannot be deleted"
                 : "Profile keys must be 1-64 ASCII letters, digits, '.', '_' or '-'";
    return false;
  }
  if (!State().ready_sent || State().stopping || !g_browser_process ||
      !g_browser_process->profile_manager()) {
    *error = "Chromium runtime is not ready";
    return false;
  }
  ProfileManager* manager = g_browser_process->profile_manager();
  *path = manager->user_data_dir().AppendASCII("Cobble-" + value);
  *loaded_profile = manager->GetProfileByPath(*path);
  error->clear();
  return true;
}

bool HasProfileBridgeWork(const base::FilePath& path, Profile* loaded_profile) {
  const auto uses_profile = [&path, loaded_profile](Profile* profile) {
    if (!profile) {
      return false;
    }
    Profile* original = profile->GetOriginalProfile();
    return profile == loaded_profile || original == loaded_profile ||
           original->GetPath() == path;
  };
  if (std::ranges::any_of(State().contexts, [&uses_profile](CCSContext* item) {
        return item && uses_profile(item->profile);
      }) ||
      std::ranges::any_of(State().pages, [&uses_profile](CCSPage* item) {
        return item && !item->closed && item->web_contents() &&
               uses_profile(Profile::FromBrowserContext(
                   item->web_contents()->GetBrowserContext()));
      }) ||
      std::ranges::any_of(State().pending_popups,
                          [&uses_profile](const auto& item) {
        return item->web_contents() &&
               uses_profile(Profile::FromBrowserContext(
                   item->web_contents()->GetBrowserContext()));
      })) {
    return true;
  }
  return HasPendingProfileOpen(path);
}

bool HasPendingProfileOpen(const base::FilePath& path) {
  return std::ranges::any_of(State().pending_context_opens,
                             [&path](const PendingContextOpen* item) {
    return item && item->profile_path == path;
  });
}

bool HasContextLease(Profile* profile) {
  return std::any_of(State().private_profiles.begin(),
                     State().private_profiles.end(),
                     [profile](const auto& item) {
                       return item.profile == profile && item.leases;
                     });
}

bool RetainPrivateProfileLease(Profile* profile) {
  if (State().stopping) {
    return false;
  }
  auto found = std::find_if(State().private_profiles.begin(),
                            State().private_profiles.end(),
                            [profile](const auto& item) {
                              return item.profile == profile;
                            });
  if (found == State().private_profiles.end()) {
    return false;
  }
  ++found->leases;
  return true;
}

void ReleasePrivateProfileLease(Profile* profile) {
  if (!State().stopping) {
    ReleasePrivateProfileLeaseInternal(profile);
  }
}

bool DeferAppQuit(bool system_shutdown) {
  BridgeState& state = State();
  if (!state.enabled || state.stopping || state.quit_resumed ||
      !state.client.app_quit_requested) {
    return false;
  }
  if (!state.quit_deferred) {
    state.quit_deferred = true;
    state.client.app_quit_requested(state.client.user_data,
                                    static_cast<uint8_t>(system_shutdown));
  }
  return true;
}

bool HandleAppReopen() {
  BridgeState& state = State();
  if (!state.enabled || state.stopping || state.quit_deferred ||
      !state.client.app_reopen) {
    return false;
  }
  state.client.app_reopen(state.client.user_data);
  return true;
}

bool HandleAppOpenURLs(void* native_urls) {
  BridgeState& state = State();
  if (!state.enabled || state.stopping || !state.client.app_open_urls ||
      !native_urls) {
    return false;
  }
  NSArray<NSURL*>* urls = (__bridge NSArray<NSURL*>*)native_urls;
  std::vector<std::string> values;
  values.reserve(urls.count);
  for (NSURL* url in urls) {
    const char* value = url.absoluteString.UTF8String;
    if (value) {
      values.emplace_back(value);
    }
  }
  std::vector<const char*> pointers;
  pointers.reserve(values.size());
  for (const std::string& value : values) {
    pointers.push_back(value.c_str());
  }
  state.client.app_open_urls(state.client.user_data, pointers.data(),
                             pointers.size());
  return true;
}

bool NotifyDownloadCreated(CCSPageRef page,
                           CCSDownloadRef download,
                           const char* suggested_filename) {
  BridgeState& state = State();
  if (state.stopping || !state.client.download_created) {
    return false;
  }
  state.client.download_created(state.client.user_data, page, download,
                                suggested_filename);
  return true;
}

void NotifyDownloadStateChanged(CCSDownloadRef download,
                                const CCSDownloadStateV1* download_state) {
  BridgeState& state = State();
  if (!state.stopping && state.client.download_state_changed) {
    state.client.download_state_changed(state.client.user_data, download,
                                        download_state);
  }
}

}  // namespace cobble_chromium
