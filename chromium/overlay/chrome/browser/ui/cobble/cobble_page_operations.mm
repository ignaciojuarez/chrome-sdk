// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/ui/cobble/cobble_local_file.h"

#include <algorithm>
#include <cmath>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/files/file_util.h"
#include "base/json/json_writer.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/ui/browser_commands.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/security_state/content/content_utils.h"
#include "components/security_state/core/security_state.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/mhtml_generation_params.h"
#include "net/cert/cert_status_flags.h"
#include "net/cert/x509_certificate.h"
#include "printing/buildflags/buildflags.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/boringssl/src/include/openssl/pool.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

namespace {

constexpr int kMaxViewportDimension = 16384;
constexpr int64_t kMaxViewportPixels = 64 * 1024 * 1024;
constexpr size_t kMaxViewportPNGBytes = 256 * 1024 * 1024;
constexpr size_t kMaxDOMBytes = 64 * 1024 * 1024;
constexpr int64_t kMaxMHTMLBytes = 512 * 1024 * 1024;
constexpr size_t kMaxConnectionDetailsBytes = 64 * 1024;

const char* ConnectionName(const security_state::VisibleSecurityState& state) {
  if (!state.url.SchemeIsHTTPOrHTTPS()) {
    return "empty";
  }
  if (state.is_error_page || net::IsCertStatusError(state.cert_status)) {
    return "insecure";
  }
  if (state.displayed_mixed_content ||
      state.displayed_content_with_cert_errors || state.contained_mixed_form ||
      state.ran_mixed_content || state.ran_content_with_cert_errors) {
    return "mixed";
  }
  if (!state.connection_info_initialized) {
    return "unknown";
  }
  return security_state::GetSecurityLevel(state) == security_state::SECURE
             ? "secure"
             : "insecure";
}

void AppendCertError(base::ListValue& errors,
                     net::CertStatus status,
                     net::CertStatus flag,
                     const char* code) {
  if (status & flag) {
    errors.Append(code);
  }
}

base::DictValue CertificateDetails(const net::X509Certificate& source,
                                   size_t name_limit,
                                   bool& truncated) {
  const std::string subject = source.subject().GetDisplayName();
  const std::string issuer = source.issuer().GetDisplayName();
  truncated |= subject.size() > name_limit || issuer.size() > name_limit;
  base::DictValue certificate;
  certificate.Set("subject", subject.size() <= name_limit ? subject : "");
  certificate.Set("issuer", issuer.size() <= name_limit ? issuer : "");
  if (!source.valid_start().is_null()) {
    certificate.Set("validFromUnixSeconds",
                    source.valid_start().InSecondsFSinceUnixEpoch());
  }
  if (!source.valid_expiry().is_null()) {
    certificate.Set("validUntilUnixSeconds",
                    source.valid_expiry().InSecondsFSinceUnixEpoch());
  }
  return certificate;
}

class ViewportCaptureRequest;
class PageDataOperation;

std::vector<std::unique_ptr<ViewportCaptureRequest>>& ViewportCaptures();
void FinishViewportCapture(ViewportCaptureRequest* request,
                           std::vector<uint8_t> png,
                           const char* error);
std::vector<std::unique_ptr<PageDataOperation>>& PageDataOperations();
void FinishPageDataOperation(PageDataOperation* request,
                             std::vector<uint8_t> bytes,
                             std::string error);

class ViewportCaptureRequest final : public content::WebContentsObserver {
 public:
  ViewportCaptureRequest(content::WebContents* contents,
                         void* callback_data,
                         CCSPageDataCallback callback)
      : content::WebContentsObserver(contents),
        callback_data_(callback_data),
        callback_(callback) {}

  void Start(content::RenderWidgetHostView* view,
             const gfx::Size& viewport,
             const gfx::Size& output_size) {
    view->CopyFromSurface(
        gfx::Rect(viewport), output_size, base::Seconds(10),
        base::BindPostTask(
            content::GetUIThreadTaskRunner({}),
            base::BindOnce(&ViewportCaptureRequest::Captured,
                           weak_factory_.GetWeakPtr())));
  }

  void Complete(const std::vector<uint8_t>& png, const char* error) {
    weak_factory_.InvalidateWeakPtrs();
    Observe(nullptr);
    CCSPageDataCallback callback = std::exchange(callback_, nullptr);
    void* callback_data = callback_data_.get();
    callback_data_ = nullptr;
    if (callback) {
      callback(callback_data, png.empty() ? nullptr : png.data(), png.size(),
               error);
    }
  }

  bool Uses(content::WebContents* contents) const {
    return web_contents() == contents;
  }

  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame()) {
      FinishViewportCapture(
          this, {},
          "The page navigated while Cobble was taking the screenshot");
    }
  }

  void WebContentsDestroyed() override {
    FinishViewportCapture(
        this, {}, "The page closed while Cobble was taking the screenshot");
  }

 private:
  struct EncodeResult {
    std::vector<uint8_t> png;
    std::string error;
  };

  static EncodeResult Encode(SkBitmap bitmap) {
    const int64_t pixels =
        static_cast<int64_t>(bitmap.width()) * bitmap.height();
    if (bitmap.width() > kMaxViewportDimension ||
        bitmap.height() > kMaxViewportDimension || pixels <= 0 ||
        pixels > kMaxViewportPixels) {
      return {{}, "The captured page viewport is too large"};
    }
    auto png = gfx::PNGCodec::EncodeBGRASkBitmap(
        bitmap, /*discard_transparency=*/false);
    if (!png || png->empty() || png->size() > kMaxViewportPNGBytes) {
      return {{}, "Chromium could not encode the page screenshot"};
    }
    return {std::move(*png), {}};
  }

  void Captured(const content::CopyFromSurfaceResult& result) {
    if (!result.has_value() || result->bitmap.drawsNothing()) {
      FinishViewportCapture(this, {},
                            "Chromium could not capture the visible page");
      return;
    }
    SkBitmap bitmap = result->bitmap;
    bitmap.setImmutable();
    if (!base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&ViewportCaptureRequest::Encode,
                           std::move(bitmap)),
            base::BindOnce(&ViewportCaptureRequest::Encoded,
                           weak_factory_.GetWeakPtr()))) {
      FinishViewportCapture(this, {},
                            "Chromium stopped before encoding the screenshot");
    }
  }

  void Encoded(EncodeResult result) {
    FinishViewportCapture(this, std::move(result.png),
                          result.error.empty() ? nullptr
                                               : result.error.c_str());
  }

  raw_ptr<void> callback_data_ = nullptr;
  CCSPageDataCallback callback_ = nullptr;
  base::WeakPtrFactory<ViewportCaptureRequest> weak_factory_{this};
};

class PageDataOperation final : public content::WebContentsObserver {
 public:
  PageDataOperation(content::WebContents* contents,
                    void* callback_data,
                    CCSPageDataCallback callback)
      : content::WebContentsObserver(contents),
        callback_data_(callback_data),
        callback_(callback) {}

  void StartDOM() {
    content::RenderFrameHost* frame = web_contents()->GetPrimaryMainFrame();
    if (!frame) {
      FinishPageDataOperation(this, {}, "The page has no current document");
      return;
    }
    frame->ExecuteJavaScriptInIsolatedWorld(
        u"document.documentElement ? document.documentElement.outerHTML : ''",
        base::BindOnce(&PageDataOperation::DOMReady,
                       weak_factory_.GetWeakPtr()),
        ISOLATED_WORLD_ID_APPLESCRIPT);
  }

  void StartMHTML() {
    if (!base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE,
            {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&PageDataOperation::CreateTemporaryPath),
            base::BindOnce(&PageDataOperation::TemporaryPathReady,
                           weak_factory_.GetWeakPtr()))) {
      FinishPageDataOperation(this, {},
                              "Chromium stopped before creating the archive");
    }
  }

  void Complete(const std::vector<uint8_t>& bytes, const std::string& error) {
    weak_factory_.InvalidateWeakPtrs();
    Observe(nullptr);
    CCSPageDataCallback callback = std::exchange(callback_, nullptr);
    void* callback_data = callback_data_.get();
    callback_data_ = nullptr;
    if (callback) {
      callback(callback_data, bytes.empty() ? nullptr : bytes.data(),
               bytes.size(), error.empty() ? nullptr : error.c_str());
    }
  }

  bool Uses(content::WebContents* contents) const {
    return web_contents() == contents;
  }

  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (handle->IsInPrimaryMainFrame() && !handle->IsSameDocument()) {
      FinishPageDataOperation(
          this, {}, "The page navigated while Cobble was reading its contents");
    }
  }

  void WebContentsDestroyed() override {
    FinishPageDataOperation(
        this, {}, "The page closed while Cobble was reading its contents");
  }

 private:
  struct FileResult {
    base::FilePath path;
    std::vector<uint8_t> bytes;
    std::string error;
    base::ScopedClosureRunner cleanup;
  };

  static FileResult CreateTemporaryPath() {
    base::FilePath path;
    if (!base::CreateTemporaryFile(&path)) {
      return {{}, {}, "Chromium could not create a temporary archive file", {}};
    }
    base::ScopedClosureRunner cleanup(base::BindOnce(
        &PageDataOperation::DeleteTemporaryPath, path));
    return {std::move(path), {}, {}, std::move(cleanup)};
  }

  static FileResult ReadAndDelete(base::FilePath path,
                                  base::ScopedClosureRunner cleanup) {
    std::string contents;
    const bool read =
        base::ReadFileToStringWithMaxSize(path, &contents, kMaxMHTMLBytes);
    if (!read || contents.empty()) {
      return {{}, {}, "Chromium could not read the MHTML archive", {}};
    }
    return {{}, std::vector<uint8_t>(contents.begin(), contents.end()), {}, {}};
  }

  void DOMReady(base::Value value) {
    const std::string* dom = value.GetIfString();
    if (!dom || dom->empty() || dom->size() > kMaxDOMBytes) {
      FinishPageDataOperation(
          this, {}, "Chromium returned an empty or oversized current DOM");
      return;
    }
    FinishPageDataOperation(
        this, std::vector<uint8_t>(dom->begin(), dom->end()), {});
  }

  static void DeleteTemporaryPath(base::FilePath path) {
    if (!path.empty()) {
      base::DeleteFile(path);
    }
  }

  static void TemporaryPathReady(base::WeakPtr<PageDataOperation> request,
                                 FileResult result) {
    if (!request) {
      return;
    }
    if (!result.error.empty()) {
      FinishPageDataOperation(request.get(), {}, std::move(result.error));
      return;
    }
    content::MHTMLGenerationParams params(result.path);
    request->web_contents()->GenerateMHTML(
        params, base::BindOnce(&PageDataOperation::MHTMLGenerated,
                               request, std::move(result.path),
                               std::move(result.cleanup)));
  }

  static void MHTMLGenerated(base::WeakPtr<PageDataOperation> request,
                             base::FilePath path,
                             base::ScopedClosureRunner cleanup,
                             int64_t file_size) {
    if (!request) {
      return;
    }
    if (file_size <= 0 || file_size > kMaxMHTMLBytes) {
      FinishPageDataOperation(
          request.get(), {},
          "Chromium could not create a bounded MHTML archive");
      return;
    }
    if (!base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE,
            {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&PageDataOperation::ReadAndDelete, std::move(path),
                           std::move(cleanup)),
            base::BindOnce(&PageDataOperation::FileReady,
                           request))) {
      FinishPageDataOperation(request.get(), {},
                              "Chromium stopped before reading the archive");
      return;
    }
  }

  void FileReady(FileResult result) {
    FinishPageDataOperation(this, std::move(result.bytes),
                            std::move(result.error));
  }

  raw_ptr<void> callback_data_ = nullptr;
  CCSPageDataCallback callback_ = nullptr;
  base::WeakPtrFactory<PageDataOperation> weak_factory_{this};
};

std::vector<std::unique_ptr<ViewportCaptureRequest>>& ViewportCaptures() {
  static base::NoDestructor<
      std::vector<std::unique_ptr<ViewportCaptureRequest>>>
      requests;
  return *requests;
}

std::vector<std::unique_ptr<PageDataOperation>>& PageDataOperations() {
  static base::NoDestructor<std::vector<std::unique_ptr<PageDataOperation>>>
      requests;
  return *requests;
}

void FinishPageDataOperation(PageDataOperation* request,
                             std::vector<uint8_t> bytes,
                             std::string error) {
  auto& requests = PageDataOperations();
  auto found = std::find_if(requests.begin(), requests.end(),
                            [request](const auto& candidate) {
                              return candidate.get() == request;
                            });
  if (found == requests.end()) {
    return;
  }
  std::unique_ptr<PageDataOperation> owned = std::move(*found);
  requests.erase(found);
  owned->Complete(bytes, error);
}

void FinishViewportCapture(ViewportCaptureRequest* request,
                           std::vector<uint8_t> png,
                           const char* error) {
  auto& requests = ViewportCaptures();
  auto found = std::find_if(requests.begin(), requests.end(),
                            [request](const auto& candidate) {
                              return candidate.get() == request;
                            });
  if (found == requests.end()) {
    return;
  }
  std::unique_ptr<ViewportCaptureRequest> owned = std::move(*found);
  requests.erase(found);
  owned->Complete(png, error);
}

void CancelViewportCapturesForShutdown() {
  auto requests = std::move(ViewportCaptures());
  ViewportCaptures().clear();
  for (auto& request : requests) {
    request->Complete({}, "Chromium stopped while taking the screenshot");
  }
}

void CancelPageDataOperationsForShutdown() {
  auto requests = std::move(PageDataOperations());
  PageDataOperations().clear();
  for (auto& request : requests) {
    request->Complete({}, "Chromium stopped while reading page contents");
  }
}

void CompleteViewportCaptureImmediately(void* callback_data,
                                        CCSPageDataCallback callback,
                                        const char* error) {
  if (callback) {
    callback(callback_data, nullptr, 0, error);
  }
}

bool IsBoundedViewport(const gfx::Size& size) {
  return !size.IsEmpty() && size.width() <= kMaxViewportDimension &&
         size.height() <= kMaxViewportDimension &&
         static_cast<int64_t>(size.width()) * size.height() <=
             kMaxViewportPixels;
}

}  // namespace

namespace cobble_chromium {

void CancelPageCaptures(content::WebContents* contents) {
  while (contents) {
    auto found = std::find_if(
        ViewportCaptures().begin(), ViewportCaptures().end(),
        [contents](const auto& request) { return request->Uses(contents); });
    if (found == ViewportCaptures().end()) {
      break;
    }
    FinishViewportCapture(
        found->get(), {},
        "The page closed while Cobble was taking the screenshot");
  }
  while (contents) {
    auto found = std::find_if(
        PageDataOperations().begin(), PageDataOperations().end(),
        [contents](const auto& request) { return request->Uses(contents); });
    if (found == PageDataOperations().end()) {
      break;
    }
    FinishPageDataOperation(
        found->get(), {},
        "The page closed while Cobble was reading its contents");
  }
}

}  // namespace cobble_chromium

int32_t CCSPageFind(CCSPageRef page, const char* text_utf8, uint8_t backwards) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* contents = cobble_chromium::PageWebContents(page);
  if (!contents || !text_utf8) {
    return -1;
  }
  auto* helper = find_in_page::FindTabHelper::FromWebContents(contents);
  if (!helper) {
    return -1;
  }
  // Chromium owns request IDs, repeated searches, cross-frame matching and
  // highlighting. Empty text clears the active search through this same API.
  const std::u16string text = base::UTF8ToUTF16(text_utf8);
  helper->StartFinding(text, !backwards,
                       /*case_sensitive=*/false, /*find_match=*/true);
  return helper->find_text().empty() ? 0 : helper->current_find_request_id();
}

double CCSPageGetZoomFactor(CCSPageRef page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* contents = cobble_chromium::PageWebContents(page);
  auto* controller = contents ? zoom::ZoomController::FromWebContents(contents)
                              : nullptr;
  return controller ? blink::ZoomLevelToZoomFactor(controller->GetZoomLevel())
                    : 0;
}

uint8_t CCSPageSetZoomFactor(CCSPageRef page, double factor) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!std::isfinite(factor) || factor <= 0) {
    return 0;
  }
  auto* contents = cobble_chromium::PageWebContents(page);
  auto* controller = contents ? zoom::ZoomController::FromWebContents(contents)
                              : nullptr;
  if (!controller) {
    return 0;
  }
  // The host owns zoom UI. Keep zoom local to this tab rather than persisting
  // a second browser's per-origin preference or showing Chrome's zoom bubble.
  controller->SetShowsNotificationBubble(false);
  controller->SetZoomMode(zoom::ZoomController::ZOOM_MODE_ISOLATED);
  return controller->SetZoomLevel(blink::ZoomFactorToZoomLevel(std::clamp(
      factor, blink::kMinimumBrowserZoomFactor, blink::kMaximumBrowserZoomFactor)));
}

uint8_t CCSPageSetAudioMuted(CCSPageRef page, uint8_t muted) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* contents = cobble_chromium::PageWebContents(page);
  if (!contents) {
    return 0;
  }
  contents->SetAudioMuted(muted != 0);
  return 1;
}

uint8_t CCSPageIsAudioMuted(CCSPageRef page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* contents = cobble_chromium::PageWebContents(page);
  return static_cast<uint8_t>(contents && contents->IsAudioMuted());
}

uint8_t CCSPageReloadFromOrigin(CCSPageRef page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  auto* contents = cobble_chromium::PageWebContents(page);
  if (!contents) {
    return 0;
  }
  if (cobble_chromium::IsLocalFileActive(page)) {
    // The client routes this through async openLocalFile so validation errors
    // remain visible and the old document survives a failed revalidation.
    return 0;
  }
  contents->GetController().Reload(content::ReloadType::BYPASSING_CACHE,
                                   /*check_for_repost=*/true);
  return 1;
}

uint8_t CCSPagePrint(CCSPageRef page) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
#if BUILDFLAG(ENABLE_PRINTING)
  auto* contents = cobble_chromium::PageWebContents(page);
  auto* browser = contents ? GlobalBrowserCollection::GetInstance()
                                 ->FindBrowserWithTab(contents)
                           : nullptr;
  if (!browser ||
      browser->GetTabStripModel()->GetActiveWebContents() != contents ||
      !chrome::CanPrint(browser)) {
    return 0;
  }
  chrome::Print(browser);
  return 1;
#else
  return 0;
#endif
}

void CCSPageCaptureViewportPNG(CCSPageRef page,
                               void* callback_data,
                               CCSPageDataCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  if (cobble_chromium::IsStopping()) {
    CompleteViewportCaptureImmediately(
        callback_data, callback,
        "Chromium stopped before taking the screenshot");
    return;
  }
  auto* contents = cobble_chromium::PageWebContents(page);
  auto* view = contents ? contents->GetRenderWidgetHostView() : nullptr;
  if (!contents || contents->IsCrashed() || !view ||
      !view->IsSurfaceAvailableForCopy()) {
    CompleteViewportCaptureImmediately(
        callback_data, callback,
        "The page has no visible area to capture");
    return;
  }
  const gfx::Size viewport = view->GetVisibleViewportSize();
  const gfx::Size output_size = view->GetVisibleViewportSizeDevicePx();
  if (!IsBoundedViewport(viewport) || !IsBoundedViewport(output_size)) {
    CompleteViewportCaptureImmediately(
        callback_data, callback,
        "The page viewport is empty or too large to capture");
    return;
  }

  cobble_chromium::RegisterShutdownCallback(
      &CancelViewportCapturesForShutdown);
  auto request = std::make_unique<ViewportCaptureRequest>(
      contents, callback_data, callback);
  auto* request_ptr = request.get();
  ViewportCaptures().push_back(std::move(request));
  request_ptr->Start(view, viewport, output_size);
}

void CCSPageCurrentDOM(CCSPageRef page,
                       void* callback_data,
                       CCSPageDataCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  auto* contents = cobble_chromium::PageWebContents(page);
  if (cobble_chromium::IsStopping() || !contents || contents->IsCrashed()) {
    CompleteViewportCaptureImmediately(
        callback_data, callback, "The page has no current DOM");
    return;
  }
  cobble_chromium::RegisterShutdownCallback(
      &CancelPageDataOperationsForShutdown);
  auto request =
      std::make_unique<PageDataOperation>(contents, callback_data, callback);
  auto* request_ptr = request.get();
  PageDataOperations().push_back(std::move(request));
  request_ptr->StartDOM();
}

void CCSPageCreateMHTMLArchive(CCSPageRef page,
                               void* callback_data,
                               CCSPageDataCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  auto* contents = cobble_chromium::PageWebContents(page);
  if (cobble_chromium::IsStopping() || !contents || contents->IsCrashed()) {
    CompleteViewportCaptureImmediately(
        callback_data, callback, "The page cannot create an MHTML archive");
    return;
  }
  cobble_chromium::RegisterShutdownCallback(
      &CancelPageDataOperationsForShutdown);
  auto request =
      std::make_unique<PageDataOperation>(contents, callback_data, callback);
  auto* request_ptr = request.get();
  PageDataOperations().push_back(std::move(request));
  request_ptr->StartMHTML();
}

void CCSPageCopyConnectionDetailsJSON(CCSPageRef page,
                                      void* callback_data,
                                      CCSPageDataCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  auto* contents = cobble_chromium::PageWebContents(page);
  if (cobble_chromium::IsStopping() || !contents) {
    callback(callback_data, nullptr, 0,
             "The page cannot provide connection details");
    return;
  }

  const GURL visible_url = contents->GetVisibleURL();
  std::unique_ptr<security_state::VisibleSecurityState> security =
      security_state::GetVisibleSecurityState(contents);
  const bool matches = !contents->IsCrashed() && security &&
                       security->url == visible_url;
  const bool available =
      matches && (!visible_url.SchemeIsHTTPOrHTTPS() ||
                  security->connection_info_initialized);

  base::DictValue root;
  root.Set("schemaVersion", 1);
  root.Set("available", available);
  root.Set("url", visible_url.spec());
  root.Set("connection", available ? ConnectionName(*security) : "unknown");

  base::ListValue cert_errors;
  base::DictValue mixed;
  mixed.Set("displayed", matches && security->displayed_mixed_content);
  mixed.Set("ran", matches && security->ran_mixed_content);
  mixed.Set("containedForm", matches && security->contained_mixed_form);
  mixed.Set("displayedWithCertificateErrors",
            matches && security->displayed_content_with_cert_errors);
  mixed.Set("ranWithCertificateErrors",
            matches && security->ran_content_with_cert_errors);

  if (available) {
    const net::CertStatus status = security->cert_status;
    AppendCertError(cert_errors, status, net::CERT_STATUS_COMMON_NAME_INVALID,
                    "commonNameInvalid");
    AppendCertError(cert_errors, status, net::CERT_STATUS_DATE_INVALID,
                    "dateInvalid");
    AppendCertError(cert_errors, status, net::CERT_STATUS_AUTHORITY_INVALID,
                    "authorityInvalid");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_NO_REVOCATION_MECHANISM,
                    "noRevocationMechanism");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_UNABLE_TO_CHECK_REVOCATION,
                    "unableToCheckRevocation");
    AppendCertError(cert_errors, status, net::CERT_STATUS_REVOKED, "revoked");
    AppendCertError(cert_errors, status, net::CERT_STATUS_INVALID, "invalid");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_WEAK_SIGNATURE_ALGORITHM,
                    "weakSignature");
    AppendCertError(cert_errors, status, net::CERT_STATUS_NON_UNIQUE_NAME,
                    "nonUniqueName");
    AppendCertError(cert_errors, status, net::CERT_STATUS_WEAK_KEY, "weakKey");
    AppendCertError(cert_errors, status, net::CERT_STATUS_PINNED_KEY_MISSING,
                    "pinnedKeyMissing");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_NAME_CONSTRAINT_VIOLATION,
                    "nameConstraintViolation");
    AppendCertError(cert_errors, status, net::CERT_STATUS_VALIDITY_TOO_LONG,
                    "validityTooLong");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_CERTIFICATE_TRANSPARENCY_REQUIRED,
                    "certificateTransparencyRequired");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_KNOWN_INTERCEPTION_BLOCKED,
                    "knownInterceptionBlocked");
    AppendCertError(cert_errors, status,
                    net::CERT_STATUS_SELF_SIGNED_LOCAL_NETWORK,
                    "selfSignedLocalNetwork");

    if (security->certificate) {
      bool truncated = false;
      root.Set("certificate",
               CertificateDetails(*security->certificate, 4096, truncated));
      base::ListValue chain;
      size_t chain_bytes = 0;
      // Keep the wire payload bounded even for hostile names/long chains. This
      // reports Chromium's available chain; it does not invent a root or trust.
      for (const auto& buffer : security->certificate->cert_buffers()) {
        if (chain.size() == 16) {
          truncated = true;
          break;
        }
        auto certificate = net::X509Certificate::CreateFromBuffer(
            bssl::UpRef(buffer.get()), {});
        if (!certificate) {
          truncated = true;
          break;
        }
        auto details = CertificateDetails(*certificate, 1024, truncated);
        std::string encoded;
        if (!base::JSONWriter::Write(details, &encoded) ||
            chain_bytes + encoded.size() + 1 > 12 * 1024) {
          truncated = true;
          break;
        }
        chain_bytes += encoded.size() + 1;
        chain.Append(std::move(details));
      }
      root.Set("certificateChain", std::move(chain));
      root.Set("certificateChainTruncated", truncated);
    }
  }
  root.Set("certificateErrorCodes", std::move(cert_errors));
  root.Set("mixedContent", std::move(mixed));

  std::string json;
  if (!base::JSONWriter::Write(root, &json) || json.empty() ||
      json.size() > kMaxConnectionDetailsBytes) {
    callback(callback_data, nullptr, 0,
             "Chromium could not serialize bounded connection details");
    return;
  }
  callback(callback_data, reinterpret_cast<const uint8_t*>(json.data()),
           json.size(), nullptr);
}
