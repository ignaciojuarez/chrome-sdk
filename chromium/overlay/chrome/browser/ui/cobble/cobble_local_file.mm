// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_local_file.h"

#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/compiler_specific.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/files/scoped_file.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/self_deleting.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/posix/eintr_wrapper.h"
#include "base/task/thread_pool.h"
#include "chrome/browser/renderer_host/chrome_navigation_ui_data.h"
#include "content/public/browser/back_forward_cache.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/file_url_loader.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/navigation_throttle.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "net/base/filename_util.h"
#include "net/base/net_errors.h"
#include "services/network/public/cpp/not_implemented_url_loader_factory.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/self_deleting_url_loader_factory.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "url/url_constants.h"

namespace {

constexpr size_t kMaxLocalFileURLBytes = 16 * 1024;

bool LocalFileDiagnosticsEnabled() {
  return base::CommandLine::ForCurrentProcess()->HasSwitch(
      "cobble-local-file-diagnostics");
}

void LogLocalFile(const char* phase, uint64_t generation, int64_t navigation_id,
                  int64_t value = -1) {
  if (LocalFileDiagnosticsEnabled()) {
    LOG(ERROR) << "Cobble local file " << phase
               << " generation=" << generation
               << " navigation=" << navigation_id << " value=" << value;
  }
}

struct ValidatedLocalFile {
  GURL url;
  base::File file;
  std::string error;
};

class LocalFileState;

std::vector<std::unique_ptr<LocalFileState>> &LocalFiles() {
  static base::NoDestructor<std::vector<std::unique_ptr<LocalFileState>>> files;
  return *files;
}

class LocalFileState {
public:
  LocalFileState(CCSPageRef page, content::WebContents *contents)
      : page_(page), contents_(contents) {}

  bool Uses(CCSPageRef page) const { return page_ == page; }
  bool Uses(content::WebContents *contents) const {
    return contents_ == contents;
  }
  bool HasGrantFor(content::BrowserContext *browser_context) const {
    return (pending_ || active_url_.is_valid()) && contents_ &&
           contents_->GetBrowserContext() == browser_context;
  }

  void Open(const GURL &requested, void *callback_data,
            CCSPageDataCallback callback, bool replace_current_entry = false) {
    replace_current_entry |= active_url_ == requested;
    const uint64_t generation = ++generation_;
    auto replaced = std::move(pending_);
    pending_ = std::make_unique<Pending>(generation, requested, callback_data,
                                         callback, replace_current_entry);
    base::WeakPtr<LocalFileState> alive = weak_factory_.GetWeakPtr();
    FinishDetached(std::move(replaced),
                   "A newer local-file request replaced this one");
    if (!alive || !IsCurrent(generation)) {
      return;
    }
    if (!base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&LocalFileState::Validate, requested),
            base::BindOnce(&LocalFileState::Validated, alive, generation))) {
      Complete(generation, "Chromium stopped before validating the local file");
    }
  }

  bool IsActive() const { return active_url_.is_valid(); }

  void NavigationStarted(content::NavigationHandle *handle) {
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument() ||
        !pending_) {
      return;
    }
    auto *ui_data =
        static_cast<ChromeNavigationUIData *>(handle->GetNavigationUIData());
    if (ui_data && ui_data->cobble_local_file_token() == pending_->generation &&
        !handle->IsRendererInitiated() && handle->GetURL() == pending_->url) {
      pending_->navigation_id = handle->GetNavigationId();
      LogLocalFile("navigation-start", pending_->generation,
                   handle->GetNavigationId());
      return;
    }
    Complete(pending_->generation, "The local-file navigation was superseded");
  }

  void NavigationFinished(content::NavigationHandle *handle) {
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument()) {
      return;
    }
    if (pending_ && pending_->navigation_id == handle->GetNavigationId()) {
      const uint64_t generation = pending_->generation;
      LogLocalFile(handle->HasCommitted() ? "navigation-committed"
                                          : "navigation-failed",
                   generation, handle->GetNavigationId(),
                   handle->GetNetErrorCode());
      if (handle->HasCommitted() && !handle->IsErrorPage() &&
          handle->GetURL() == pending_->url) {
        active_url_ = pending_->url;
        content::BackForwardCache::DisableForRenderFrameHost(
            contents_->GetPrimaryMainFrame(),
            content::BackForwardCache::DisabledReason(
                content::BackForwardCache::DisabledSource::kEmbedder, 1,
                "Cobble exact local file", std::string(), "LocalFile"));
        Complete(generation, nullptr);
      } else {
        if (handle->HasCommitted()) {
          active_url_ = GURL();
        }
        Complete(generation, "Chromium could not open the selected local file");
      }
      return;
    }
    if (handle->HasCommitted()) {
      active_url_ = GURL();
    }
  }

  bool Allows(content::NavigationHandle &handle) const {
    if (!pending_ || pending_->navigation_id != handle.GetNavigationId() ||
        handle.IsRendererInitiated() || !handle.IsInPrimaryMainFrame() ||
        handle.GetURL() != pending_->url) {
      return false;
    }
    auto *ui_data =
        static_cast<ChromeNavigationUIData *>(handle.GetNavigationUIData());
    return ui_data &&
           ui_data->cobble_local_file_token() == pending_->generation;
  }

  bool HasPendingFactory(content::FrameTreeNodeId frame_tree_node_id) const {
    return pending_ && pending_->navigation_id.has_value() && contents_ &&
           contents_->GetPrimaryMainFrame() &&
           contents_->GetPrimaryMainFrame()->GetFrameTreeNodeId() ==
               frame_tree_node_id;
  }

  uint64_t pending_generation() const {
    return pending_ ? pending_->generation : 0;
  }

  bool TakeFile(uint64_t generation, const network::ResourceRequest &request,
                base::File *file) {
    if (!IsCurrent(generation) || !pending_->navigation_id ||
        request.url != pending_->url || request.method != "GET" ||
        request.destination != network::mojom::RequestDestination::kDocument ||
        !pending_->file.IsValid()) {
      return false;
    }
    *file = std::move(pending_->file);
    return true;
  }

  base::WeakPtr<LocalFileState> GetWeakPtr() {
    return weak_factory_.GetWeakPtr();
  }

  void BeforeUnloadCancelled() {
    if (pending_) {
      Complete(pending_->generation,
               "The page cancelled the local-file navigation");
    }
  }

  void RenderProcessGone() {
    active_url_ = GURL();
    if (pending_) {
      Complete(pending_->generation,
               "The page crashed while opening the local file");
    }
  }

  void Shutdown() {
    active_url_ = GURL();
    auto pending = std::move(pending_);
    contents_ = nullptr;
    page_ = nullptr;
    weak_factory_.InvalidateWeakPtrs();
    FinishDetached(std::move(pending),
                   "Chromium stopped while opening the local file");
  }

private:
  struct Pending {
    Pending(uint64_t generation, GURL url, void *callback_data,
            CCSPageDataCallback callback, bool replace_current_entry)
        : generation(generation), url(std::move(url)),
          callback_data(callback_data), callback(callback),
          replace_current_entry(replace_current_entry) {}

    uint64_t generation;
    GURL url;
    raw_ptr<void> callback_data;
    CCSPageDataCallback callback;
    bool replace_current_entry;
    base::File file;
    std::optional<int64_t> navigation_id;
  };

  static ValidatedLocalFile Validate(const GURL &requested) {
    base::FilePath path;
    if (!requested.SchemeIsFile() || requested.has_query() ||
        requested.has_ref() || !net::FileURLToFilePath(requested, &path) ||
        path.empty() || !path.IsAbsolute() || path.ReferencesParent()) {
      return {{}, {}, "The selected URL is not a canonical local file"};
    }
    if (base::FilePath::CompareEqualIgnoreCase(
            path.Extension(), FILE_PATH_LITERAL(".pdf"))) {
      return {
          {}, {}, "PDF files require local subresources and are not supported"};
    }
    base::ScopedFD fd(
        HANDLE_EINTR(open(path.value().c_str(),
                          O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW_ANY)));
    if (!fd.is_valid()) {
      return {{}, {}, "The selected local file is not readable"};
    }
    struct stat status;
    if (fstat(fd.get(), &status) != 0 || !S_ISREG(status.st_mode)) {
      return {{}, {}, "The selected path is not a regular file"};
    }
    char signature[5];
    if (HANDLE_EINTR(pread(fd.get(), signature, sizeof(signature), 0)) ==
            sizeof(signature) &&
        std::string_view(signature, sizeof(signature)) == "%PDF-") {
      return {
          {}, {}, "PDF files require local subresources and are not supported"};
    }
    char actual_path[PATH_MAX];
    if (fcntl(fd.get(), F_GETPATH, actual_path) != 0) {
      return {{}, {}, "Chromium could not resolve the selected local file"};
    }
    base::FilePath canonical(actual_path);
    if (canonical != path) {
      return {{}, {}, "The selected path is not canonical"};
    }
    GURL canonical_url = net::FilePathToFileURL(canonical);
    if (!canonical_url.is_valid() || canonical_url != requested) {
      return {{}, {}, "The selected URL is not canonical"};
    }
    return {std::move(canonical_url), base::File(std::move(fd)), {}};
  }

  void Validated(uint64_t generation, ValidatedLocalFile result) {
    if (!IsCurrent(generation)) {
      return;
    }
    if (!result.error.empty()) {
      Complete(generation, result.error.c_str());
      return;
    }
    if (!contents_ || !cobble_chromium::PageWebContents(page_) ||
        cobble_chromium::PageHasPendingPromptOrMedia(page_)) {
      Complete(generation,
               "The page became unavailable before opening the local file");
      return;
    }
    pending_->url = std::move(result.url);
    pending_->file = std::move(result.file);
    content::NavigationController::LoadURLParams params(pending_->url);
    params.transition_type = ui::PAGE_TRANSITION_TYPED;
    params.should_replace_current_entry = pending_->replace_current_entry;
    auto ui_data = std::make_unique<ChromeNavigationUIData>();
    ui_data->set_cobble_local_file_token(generation);
    params.navigation_ui_data = std::move(ui_data);

    base::WeakPtr<LocalFileState> alive = weak_factory_.GetWeakPtr();
    auto navigation = contents_->GetController().LoadURLWithParams(params);
    if (alive && IsCurrent(generation) && !navigation) {
      Complete(generation, "Chromium did not start the local-file navigation");
    }
  }

  bool IsCurrent(uint64_t generation) const {
    return pending_ && pending_->generation == generation;
  }

  void Complete(uint64_t generation, const char *error) {
    if (IsCurrent(generation)) {
      FinishDetached(std::move(pending_), error);
    }
  }

  static void FinishDetached(std::unique_ptr<Pending> pending,
                             const char *error) {
    if (pending && pending->callback) {
      pending->callback(pending->callback_data, nullptr, 0, error);
    }
  }

  raw_ptr<CCSPage> page_ = nullptr;
  raw_ptr<content::WebContents> contents_ = nullptr;
  std::unique_ptr<Pending> pending_;
  GURL active_url_;
  uint64_t generation_ = 0;
  base::WeakPtrFactory<LocalFileState> weak_factory_{this};
};

LocalFileState *StateFor(CCSPageRef page) {
  auto found =
      std::find_if(LocalFiles().begin(), LocalFiles().end(),
                   [page](const auto &state) { return state->Uses(page); });
  return found == LocalFiles().end() ? nullptr : found->get();
}

LocalFileState *StateFor(content::WebContents *contents) {
  auto found = std::find_if(
      LocalFiles().begin(), LocalFiles().end(),
      [contents](const auto &state) { return state->Uses(contents); });
  return found == LocalFiles().end() ? nullptr : found->get();
}

class DiagnosticFileObserver final : public content::FileURLLoaderObserver {
 public:
  DiagnosticFileObserver(uint64_t generation, int64_t navigation_id)
      : generation_(generation), navigation_id_(navigation_id) {}
  void OnStart() override {
    LogLocalFile("loader-start", generation_, navigation_id_);
  }
  void OnSeekComplete(int64_t result) override {
    LogLocalFile("loader-seek", generation_, navigation_id_, result);
  }
  void OnRead(base::span<char>,
              mojo::DataPipeProducer::DataSource::ReadResult* result) override {
    LogLocalFile("loader-read", generation_, navigation_id_,
                 result ? static_cast<int64_t>(result->bytes_read) : -1);
  }
  void OnDone() override {
    LogLocalFile("loader-done", generation_, navigation_id_);
  }

 private:
  const uint64_t generation_;
  const int64_t navigation_id_;
};

class ExactLocalFileFactory final
    : public network::SelfDeletingURLLoaderFactory {
public:
  static mojo::PendingRemote<network::mojom::URLLoaderFactory>
  Create(base::WeakPtr<LocalFileState> state, uint64_t generation) {
    mojo::PendingRemote<network::mojom::URLLoaderFactory> remote;
    base::MakeSelfDeleting<ExactLocalFileFactory>(
        std::move(state), generation, remote.InitWithNewPipeAndPassReceiver());
    return remote;
  }

  ExactLocalFileFactory(
      base::WeakPtr<LocalFileState> state, uint64_t generation,
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      base::SelfDeletingPassKey key)
      : network::SelfDeletingURLLoaderFactory(std::move(receiver), key),
        state_(std::move(state)), generation_(generation) {}

private:
  ~ExactLocalFileFactory() override = default;

  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      int32_t request_id, uint32_t options,
      const network::ResourceRequest &request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag &traffic_annotation)
      override {
    base::File file;
    const bool accepted = state_ && state_->TakeFile(generation_, request, &file);
    if (LocalFileDiagnosticsEnabled()) {
      LogLocalFile(accepted ? "factory-accepted" : "factory-denied", generation_,
                   -1, accepted ? file.GetLength() : -1);
      LOG(ERROR) << "Cobble local file request method=" << request.method
                 << " destination=" << static_cast<int>(request.destination);
    }
    if (!accepted) {
      mojo::Remote<network::mojom::URLLoaderClient>(std::move(client))
          ->OnComplete(
              network::URLLoaderCompletionStatus(net::ERR_ACCESS_DENIED));
      return;
    }
    std::unique_ptr<content::FileURLLoaderObserver> observer;
    if (LocalFileDiagnosticsEnabled()) {
      observer = std::make_unique<DiagnosticFileObserver>(generation_, -1);
    }
    content::CreateFileURLLoaderFromFile(request, std::move(file),
                                         std::move(loader), std::move(client),
                                         std::move(observer));
  }

  base::WeakPtr<LocalFileState> state_;
  const uint64_t generation_;
};

class LocalFileNavigationThrottle final : public content::NavigationThrottle {
public:
  explicit LocalFileNavigationThrottle(
      content::NavigationThrottleRegistry &registry)
      : content::NavigationThrottle(registry) {}
  ThrottleCheckResult WillStartRequest() override { return Check(); }
  ThrottleCheckResult WillRedirectRequest() override { return Check(); }
  const char *GetNameForLogging() override {
    return "CobbleLocalFileNavigationThrottle";
  }

private:
  ThrottleCheckResult Check() {
    if (!navigation_handle()->GetURL().SchemeIsFile()) {
      return PROCEED;
    }
    auto *page = cobble_chromium::PageForWebContents(
        navigation_handle()->GetWebContents());
    LocalFileState *state = page ? StateFor(page) : nullptr;
    if (state && state->Allows(*navigation_handle())) {
      return PROCEED;
    }
    return navigation_handle()->IsInPrimaryMainFrame()
               ? ThrottleCheckResult(CANCEL_AND_IGNORE)
               : ThrottleCheckResult(BLOCK_REQUEST, net::ERR_ACCESS_DENIED);
  }
};

void CancelAllLocalFiles() {
  auto files = std::move(LocalFiles());
  LocalFiles().clear();
  for (auto &state : files) {
    state->Shutdown();
  }
}

} // namespace

namespace cobble_chromium {

void OpenLocalFile(CCSPageRef page, const char *url_utf8, void *callback_data,
                   CCSPageDataCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  content::WebContents *contents = PageWebContents(page);
  if (!callback) {
    return;
  }
  if (!contents || IsStopping() || !url_utf8) {
    callback(callback_data, nullptr, 0, "The page is unavailable");
    return;
  }
  // SAFETY: the C API caller supplies a NUL-terminated string. Bound the scan
  // before allocating a URL so an oversized caller string cannot grow it.
  const size_t length =
      UNSAFE_BUFFERS(strnlen(url_utf8, kMaxLocalFileURLBytes + 1));
  if (length > kMaxLocalFileURLBytes) {
    callback(callback_data, nullptr, 0,
             "The selected local-file URL is too long");
    return;
  }
  GURL url(std::string_view(url_utf8, length));
  if (!url.is_valid() || !url.SchemeIsFile() ||
      PageHasPendingPromptOrMedia(page)) {
    callback(callback_data, nullptr, 0,
             "The selected local-file request is invalid or unavailable");
    return;
  }
  LocalFileState *state = StateFor(page);
  if (!state) {
    LocalFiles().push_back(std::make_unique<LocalFileState>(page, contents));
    state = LocalFiles().back().get();
    static const bool registered = [] {
      RegisterShutdownCallback(&CancelAllLocalFiles);
      return true;
    }();
    (void)registered;
  }
  state->Open(url, callback_data, callback);
}

bool IsLocalFileActive(CCSPageRef page) {
  LocalFileState *state = StateFor(page);
  return state && state->IsActive();
}

bool CanNavigateLocalFileHistory(CCSPageRef page, int offset) {
  content::WebContents *contents = PageWebContents(page);
  if (!contents) {
    return false;
  }
  content::NavigationEntry *target =
      contents->GetController().GetEntryAtOffset(offset);
  return target && !target->GetURL().SchemeIsFile();
}

void LocalFileNavigationStarted(CCSPageRef page,
                                content::NavigationHandle *handle) {
  if (LocalFileState *state = StateFor(page)) {
    state->NavigationStarted(handle);
  }
}

void LocalFileNavigationFinished(CCSPageRef page,
                                 content::NavigationHandle *handle) {
  if (LocalFileState *state = StateFor(page)) {
    state->NavigationFinished(handle);
  }
}

void LocalFileBeforeUnloadCancelled(CCSPageRef page) {
  if (LocalFileState *state = StateFor(page)) {
    state->BeforeUnloadCancelled();
  }
}

void LocalFileRenderProcessGone(CCSPageRef page) {
  if (LocalFileState *state = StateFor(page)) {
    state->RenderProcessGone();
  }
}

void CloseLocalFileForPage(CCSPageRef page) {
  auto found =
      std::find_if(LocalFiles().begin(), LocalFiles().end(),
                   [page](const auto &state) { return state->Uses(page); });
  if (found == LocalFiles().end()) {
    return;
  }
  std::unique_ptr<LocalFileState> state = std::move(*found);
  LocalFiles().erase(found);
  state->Shutdown();
}

void AddLocalFileNavigationThrottle(
    content::NavigationThrottleRegistry &registry) {
  content::NavigationHandle &handle = registry.GetNavigationHandle();
  if (IsEnabled() && PageForWebContents(handle.GetWebContents())) {
    registry.AddThrottle(
        std::make_unique<LocalFileNavigationThrottle>(registry));
  }
}

mojo::PendingRemote<network::mojom::URLLoaderFactory>
CreateLocalFileNavigationFactory(const std::string &scheme,
                                 content::FrameTreeNodeId frame_tree_node_id) {
  if (!IsEnabled() || scheme != url::kFileScheme) {
    return {};
  }
  content::WebContents *contents =
      content::WebContents::FromFrameTreeNodeId(frame_tree_node_id);
  LocalFileState *state = contents ? StateFor(contents) : nullptr;
  if (!state || !state->HasPendingFactory(frame_tree_node_id)) {
    LogLocalFile("factory-unavailable", state ? state->pending_generation() : 0,
                 -1, frame_tree_node_id.value());
    return network::NotImplementedURLLoaderFactory::Create();
  }
  LogLocalFile("factory-created", state->pending_generation(), -1,
               frame_tree_node_id.value());
  return ExactLocalFileFactory::Create(state->GetWeakPtr(),
                                       state->pending_generation());
}

bool ShouldDenyLocalFileWorkerFactories(
    content::BrowserContext *browser_context) {
  return IsEnabled() &&
         std::any_of(LocalFiles().begin(), LocalFiles().end(),
                     [browser_context](const auto &state) {
                       return state->HasGrantFor(browser_context);
                     });
}

bool ShouldDenyLocalFileSubresourceFactories(int render_process_id,
                                             int render_frame_id) {
  content::RenderFrameHost *frame =
      content::RenderFrameHost::FromID(render_process_id, render_frame_id);
  return IsEnabled() && frame &&
         PageForWebContents(content::WebContents::FromRenderFrameHost(frame));
}

bool ShouldDenyLocalFileDownload(content::WebContents *contents,
                                 const GURL &url) {
  return IsEnabled() && url.SchemeIsFile() && PageForWebContents(contents);
}

} // namespace cobble_chromium

extern "C" void CCSPageOpenLocalFile(CCSPageRef page, const char *url_utf8,
                                     void *callback_data,
                                     CCSPageDataCallback callback) {
  cobble_chromium::OpenLocalFile(page, url_utf8, callback_data, callback);
}
