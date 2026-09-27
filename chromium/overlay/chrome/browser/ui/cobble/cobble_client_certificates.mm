// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only
#include "chrome/browser/ui/cobble/cobble_client_certificates.h"

#include <algorithm>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/containers/span.h"
#include "base/command_line.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "content/browser/navigation_or_document_handle.h"
#include "content/browser/renderer_host/navigation_request.h"
#include "content/public/browser/client_certificate_delegate.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "net/ssl/ssl_cert_request_info.h"
#include "net/ssl/client_cert_store_empty.h"
#include "net/ssl/client_cert_store_mac.h"
#include "net/ssl/ssl_private_key.h"
#include "net/cert/x509_certificate.h"
#include "url/gurl.h"
#include "url/origin.h"

constexpr size_t kMaxChoices = 64;
constexpr size_t kMaxStringBytes = 1024;
constexpr size_t kMaxOriginBytes = 8192;
constexpr size_t kMaxPayloadBytes = 64 * 1024;

struct Choice {
  uint64_t id = 0;
  std::unique_ptr<net::ClientCertIdentity> identity;
  std::string subject;
  std::string issuer;
  std::string serial;
  int64_t valid_from = 0;
  int64_t valid_until = 0;
};

struct CCSClientCertificateRequest {
  uint64_t id = 0;
  CCSPageRef page = nullptr;
  raw_ptr<content::WebContents> contents = nullptr;
  scoped_refptr<content::NavigationOrDocumentHandle> context;
  std::unique_ptr<content::ClientCertificateDelegate> delegate;
  std::vector<Choice> choices;
  std::string challenger_origin;
  std::string top_level_origin;
  std::string visible_page_origin;
  std::string frame_token;
  int64_t navigation_id = 0;
  int32_t frame_process_id = -1;
  int32_t frame_routing_id = -1;
  bool navigation = false;
  bool primary_main_frame = false;
  bool choices_truncated = false;
  bool selecting = false;
  base::WeakPtrFactory<CCSClientCertificateRequest> weak_factory{this};
};

namespace {
std::vector<std::unique_ptr<CCSClientCertificateRequest>>& Requests() {
  static base::NoDestructor<std::vector<std::unique_ptr<CCSClientCertificateRequest>>> requests;
  return *requests;
}
CCSClientCertificateRequest* Find(CCSClientCertificateRequestRef request) {
  for (const auto& candidate : Requests()) if (candidate.get() == request) return candidate.get();
  return nullptr;
}
std::string Bound(std::string value) {
  if (!base::IsStringUTF8(value)) return {};
  return std::string(base::TruncateUTF8ToByteSize(value, kMaxStringBytes));
}
std::string CanonicalSerial(base::span<const uint8_t> serial) {
  while (serial.size() > 1 && serial.front() == 0) {
    serial = serial.subspan(size_t{1});
  }
  return base::HexEncode(serial);
}
bool IsLive(const CCSClientCertificateRequest& request) {
  if (!request.context || request.context->GetWebContents() != request.contents ||
      !cobble_chromium::PageAcceptsPromptResult(request.page,
                                                request.contents)) return false;
  if (request.navigation) {
    auto* navigation = request.context->GetNavigationRequest();
    return navigation && navigation->GetNavigationId() == request.navigation_id;
  }
  auto* document = request.context->GetDocument();
  return document && document->GetGlobalFrameToken().frame_token.value().ToString() ==
                         request.frame_token;
}
void Cancel(uint64_t id, bool notify) {
  auto& requests = Requests();
  auto found = std::find_if(requests.begin(), requests.end(),
                            [id](const auto& value) { return value->id == id; });
  if (found == requests.end()) return;
  auto owned = std::move(*found);
  requests.erase(found);
  content::WebContents* contents = owned->contents.get();
  if (contents) cobble_chromium::BrowserPageStateChanged(contents);
  if (notify && cobble_chromium::Client().client_certificate_cancelled) {
    cobble_chromium::Client().client_certificate_cancelled(
        cobble_chromium::Client().user_data, owned.get(), owned->id);
  }
}
void Acquired(base::WeakPtr<CCSClientCertificateRequest> weak,
              scoped_refptr<net::X509Certificate> cert,
              scoped_refptr<net::SSLPrivateKey> key) {
  auto* request = weak.get();
  if (!request || Find(request) != request) return;
  if (!key || !IsLive(*request)) {
    Cancel(request->id, true);
    return;
  }
  auto& requests = Requests();
  auto found = std::find_if(requests.begin(), requests.end(),
                            [request](const auto& value) { return value.get() == request; });
  auto owned = std::move(*found);
  requests.erase(found);
  auto delegate = std::move(owned->delegate);
  content::WebContents* contents = owned->contents.get();
  base::WeakPtr<content::WebContents> contents_alive =
      contents ? contents->GetWeakPtr() : nullptr;
  if (contents) cobble_chromium::BrowserPageStateChanged(contents);
  if (!contents_alive || cobble_chromium::IsStopping() || !IsLive(*owned)) {
    return;
  }
  delegate->ContinueWithCertificate(std::move(cert), std::move(key));
}
void CancelAll() {
  while (!Requests().empty()) Cancel(Requests().front()->id, true);
}
}  // namespace

extern "C" uint8_t CCSClientCertificateSelect(
    CCSClientCertificateRequestRef request_ref, uint64_t choice_id) {
  auto* request = Find(request_ref);
  if (!request || request->selecting || !IsLive(*request)) return 0;
  auto found = std::find_if(request->choices.begin(), request->choices.end(),
                            [choice_id](const Choice& choice) { return choice.id == choice_id; });
  if (found == request->choices.end() || !found->identity) return 0;
  request->selecting = true;
  auto identity = std::move(found->identity);
  scoped_refptr<net::X509Certificate> cert(identity->certificate());
  net::ClientCertIdentity::SelfOwningAcquirePrivateKey(
      std::move(identity), base::BindOnce(&Acquired, request->weak_factory.GetWeakPtr(),
                                         std::move(cert)));
  return 1;
}
extern "C" uint8_t CCSClientCertificateCancel(
    CCSClientCertificateRequestRef request_ref) {
  auto* request = Find(request_ref);
  if (!request || request->selecting) return 0;
  Cancel(request->id, false);
  return 1;
}

namespace cobble_chromium {
std::unique_ptr<net::ClientCertStore>
CreateRestrictedClientCertStoreForFixture() {
  constexpr char kSwitch[] = "cobble-client-cert-test-keychain";
  if (!IsEnabled() || !base::CommandLine::ForCurrentProcess()->HasSwitch(kSwitch)) {
    return nullptr;
  }
  const std::string path =
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(kSwitch);
  if (path.empty() || path.size() > 4096) {
    return std::make_unique<net::ClientCertStoreEmpty>();
  }
  base::FilePath keychain = base::FilePath::FromUTF8Unsafe(path);
  if (!keychain.IsAbsolute()) {
    return std::make_unique<net::ClientCertStoreEmpty>();
  }
  return std::make_unique<net::ClientCertStoreMac>(std::move(keychain));
}

base::OnceClosure HandleClientCertificateRequest(
    content::NavigationOrDocumentHandle* navigation_or_document,
    content::WebContents* contents,
    net::SSLCertRequestInfo* cert_request_info,
    net::ClientCertIdentityList identities,
    std::unique_ptr<content::ClientCertificateDelegate> delegate) {
  CCSPageRef page = PageForWebContents(contents);
  if (!page || !navigation_or_document || !cert_request_info || !delegate ||
      IsStopping() || !Client().client_certificate_requested || identities.empty() ||
      PageHasPendingPromptOrMedia(page)) return {};
  auto request = std::make_unique<CCSClientCertificateRequest>();
  request->id = NextPromptRequestID();
  request->page = page;
  request->contents = contents;
  request->context = base::WrapRefCounted(navigation_or_document);
  request->delegate = std::move(delegate);
  request->navigation = navigation_or_document->GetNavigationRequest() != nullptr;
  request->primary_main_frame = navigation_or_document->IsInPrimaryMainFrame();
  request->challenger_origin = url::Origin::Create(
      GURL("https://" + cert_request_info->host_and_port.ToString())).Serialize();
  if (auto top = navigation_or_document->GetTopmostFrameOrigin())
    request->top_level_origin = top->Serialize();
  auto* main = contents->GetPrimaryMainFrame();
  if (main) request->visible_page_origin = main->GetLastCommittedOrigin().Serialize();
  if (auto* navigation = navigation_or_document->GetNavigationRequest()) {
    request->navigation_id = navigation->GetNavigationId();
  } else if (auto* document = navigation_or_document->GetDocument()) {
    auto id = document->GetGlobalId();
    request->frame_process_id = id.child_id.value();
    request->frame_routing_id = id.frame_routing_id;
    request->frame_token = document->GetGlobalFrameToken().frame_token.value().ToString();
  } else {
    return {};
  }
  if (request->challenger_origin.size() > kMaxOriginBytes ||
      request->top_level_origin.size() > kMaxOriginBytes ||
      request->visible_page_origin.size() > kMaxOriginBytes ||
      request->frame_token.size() > kMaxStringBytes) {
    return {};
  }
  size_t payload = request->challenger_origin.size() + request->top_level_origin.size() +
                   request->visible_page_origin.size() + request->frame_token.size();
  for (auto& identity : identities) {
    if (request->choices.size() == kMaxChoices) { request->choices_truncated = true; break; }
    scoped_refptr<net::X509Certificate> cert(identity->certificate());
    if (!cert) { request->choices_truncated = true; continue; }
    Choice choice;
    choice.id = NextPromptRequestID();
    choice.subject = Bound(cert->subject().GetDisplayName());
    choice.issuer = Bound(cert->issuer().GetDisplayName());
    choice.serial = Bound(CanonicalSerial(cert->serial_number()));
    choice.valid_from = static_cast<int64_t>(cert->valid_start().InSecondsFSinceUnixEpoch());
    choice.valid_until = static_cast<int64_t>(cert->valid_expiry().InSecondsFSinceUnixEpoch());
    const size_t added = choice.subject.size() + choice.issuer.size() + choice.serial.size();
    if (payload + added > kMaxPayloadBytes) { request->choices_truncated = true; continue; }
    payload += added;
    choice.identity = std::move(identity);
    request->choices.push_back(std::move(choice));
  }
  if (request->choices.empty()) return {};
  auto* handle = request.get();
  const uint64_t request_id = handle->id;
  RegisterShutdownCallback(&CancelAll);
  Requests().push_back(std::move(request));
  if (!IsLive(*handle)) { Cancel(handle->id, false); return {}; }
  std::vector<CCSClientCertificateChoiceV1> choices;
  choices.reserve(handle->choices.size());
  for (const auto& choice : handle->choices) {
    choices.push_back({sizeof(CCSClientCertificateChoiceV1), choice.id,
      choice.subject.c_str(), choice.issuer.c_str(), choice.serial.c_str(),
      choice.valid_from, choice.valid_until});
  }
  CCSClientCertificateRequestV1 value = {
    sizeof(CCSClientCertificateRequestV1), handle->id,
    handle->challenger_origin.c_str(), handle->top_level_origin.c_str(),
    handle->visible_page_origin.c_str(), static_cast<uint8_t>(handle->navigation),
    handle->navigation_id, handle->frame_process_id, handle->frame_routing_id,
    handle->frame_token.empty() ? nullptr : handle->frame_token.c_str(),
    static_cast<uint8_t>(handle->primary_main_frame), choices.data(), choices.size(),
    static_cast<uint8_t>(handle->choices_truncated)};
  BrowserPageStateChanged(contents);
  CCSClientCertificateRequest* current = Find(handle);
  if (!current || current->id != request_id) return {};
  handle = current;
  if (IsStopping() || !IsLive(*handle)) {
    Cancel(request_id, false);
    return {};
  }
  Client().client_certificate_requested(Client().user_data, page, handle, &value);
  return base::BindOnce(&Cancel, request_id, true);
}
bool PageHasPendingClientCertificate(content::WebContents* contents) {
  return std::any_of(Requests().begin(), Requests().end(),
                     [contents](const auto& request) { return request->contents == contents; });
}
void CancelClientCertificatesForPage(content::WebContents* contents) {
  std::vector<uint64_t> ids;
  for (const auto& request : Requests()) if (request->contents == contents) ids.push_back(request->id);
  for (uint64_t id : ids) Cancel(id, true);
}
}  // namespace cobble_chromium
