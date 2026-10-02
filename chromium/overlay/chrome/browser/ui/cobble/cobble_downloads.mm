// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_downloads.h"

#include <algorithm>
#include <cerrno>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <utility>
#include <vector>

#include "base/auto_reset.h"
#include "base/check.h"
#include "base/files/file.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/profile.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_task_runner.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/download_item_utils.h"
#include "ui/shell_dialogs/selected_file_info.h"

namespace {

std::vector<CCSDownload*>& Downloads() {
  static base::NoDestructor<std::vector<CCSDownload*>> downloads;
  return *downloads;
}

class CancelRequest {
 public:
  CancelRequest(void* callback_data, CCSDownloadCancelCallback callback)
      : callback_data_(callback_data), callback_(callback) {}

  void Complete() {
    CCSDownloadCancelCallback callback = std::exchange(callback_, nullptr);
    void* callback_data = callback_data_.get();
    callback_data_ = nullptr;
    if (callback) {
      callback(callback_data);
    }
  }

 private:
  raw_ptr<void> callback_data_ = nullptr;
  CCSDownloadCancelCallback callback_ = nullptr;
};

std::string FailureMessage(download::DownloadItem* item) {
  if (item->IsDangerous()) {
    return "Chromium blocked this download because it may be unsafe.";
  }
  if (item->IsInsecure()) {
    return "Chromium blocked this download because it was delivered insecurely.";
  }
  return std::string("Chromium download failed: ") +
         download::DownloadInterruptReasonToString(item->GetLastReason());
}

bool IsNewFilesystemEntry(const base::FilePath& path) {
  base::stat_wrapper_t info;
  return base::File::Lstat(path, &info) != 0 && errno == ENOENT;
}

}  // namespace

struct CCSDownload final : public download::DownloadItem::Observer {
  CCSDownload(download::DownloadItem* item,
              DownloadTargetDeterminerDelegate::ConfirmationCallback callback)
      : item_(item), confirmation_callback_(std::move(callback)) {
    Profile* profile = Profile::FromBrowserContext(
        content::DownloadItemUtils::GetBrowserContext(item));
    CHECK(profile);
    profile_keep_alive_ = ScopedProfileKeepAlive::TryAcquire(
        profile->GetOriginalProfile(),
        ProfileKeepAliveOrigin::kDownloadInProgress);
    requires_private_profile_lease_ = profile->IsOffTheRecord();
    has_private_profile_lease_ =
        cobble_chromium::RetainPrivateProfileLease(profile);
    private_profile_ = has_private_profile_lease_ ? profile : nullptr;
    item_->AddObserver(this);
    Downloads().push_back(this);
  }

  bool IsReady() const {
    return profile_keep_alive_ &&
           (!requires_private_profile_lease_ || has_private_profile_lease_);
  }

  bool HasPendingWorkFor(Profile* profile) const {
    return profile_keep_alive_ && profile_keep_alive_->profile() == profile &&
           (!terminal_delivered_ || destination_validation_pending_ ||
            !cancel_requests_.empty());
  }

  void RejectWithoutClient() {
    client_released_ = true;
    Cancel(nullptr, nullptr);
  }

  ~CCSDownload() override {
    std::erase(Downloads(), this);
    if (item_) {
      item_->RemoveObserver(this);
    }
    if (has_private_profile_lease_) {
      cobble_chromium::ReleasePrivateProfileLease(private_profile_);
    }
  }

  void NotifyCreated(const base::FilePath& suggested_path) {
    CCSPageRef page = cobble_chromium::PageForWebContents(
        content::DownloadItemUtils::GetWebContents(item_));
    const std::string filename = suggested_path.BaseName().AsUTF8Unsafe();
    bool handled = false;
    {
      base::AutoReset<bool> callback_guard(&in_client_callback_, true);
      handled = page && cobble_chromium::NotifyDownloadCreated(
                            page, this, filename.c_str());
    }
    if (!handled) {
      client_released_ = true;
      Cancel(nullptr, nullptr);
    }
    MaybeDelete();
  }

  void SetDestination(const char* staging_path_utf8) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (!confirmation_callback_ || destination_validation_pending_) {
      return;
    }
    const base::FilePath staging_path = staging_path_utf8
                                            ? base::FilePath::FromUTF8Unsafe(
                                                  staging_path_utf8)
                                            : base::FilePath();
    if (staging_path.empty() || !staging_path.IsAbsolute() ||
        staging_path.ReferencesParent()) {
      auto callback = std::move(confirmation_callback_);
      confirmation_callback_.Reset();
      std::move(callback).Run(DownloadConfirmationResult::CANCELED,
                              ui::SelectedFileInfo());
      return;
    }
    destination_validation_pending_ = true;
    // lstat rejects every existing entry, including dangling symlinks. Run it
    // on Chromium's download sequence because filesystem metadata can block.
    if (!download::GetDownloadTaskRunner()->PostTaskAndReplyWithResult(
            FROM_HERE, base::BindOnce(&IsNewFilesystemEntry, staging_path),
            base::BindOnce(&CCSDownload::FinishDestinationValidation,
                           weak_factory_.GetWeakPtr(), staging_path))) {
      destination_validation_pending_ = false;
      ResolveDestinationAsCancelled();
    }
  }

  void Cancel(void* callback_data, CCSDownloadCancelCallback callback) {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    if (callback) {
      cancel_requests_.push_back(
          std::make_unique<CancelRequest>(callback_data, callback));
    }
    explicit_cancel_ = true;
    if (terminal_delivered_) {
      CompleteCancelRequests();
      MaybeDelete();
      return;
    }
    if (terminal_scheduled_) {
      return;
    }
    terminal_scheduled_ = true;
    terminal_status_ = CCS_DOWNLOAD_CANCELLED;
    ResolveDestinationAsCancelled();
    if (item_ && item_->GetState() != download::DownloadItem::COMPLETE &&
        item_->GetState() != download::DownloadItem::CANCELLED) {
      item_->Cancel(true);
    }
    QueueFileBarrier();
  }

  uint32_t ControlState() const {
    if (!item_ || client_released_ || terminal_scheduled_ ||
        confirmation_callback_ || destination_validation_pending_ ||
        item_->IsDangerous() || item_->IsInsecure()) {
      return 0;
    }
    if (item_->GetState() == download::DownloadItem::INTERRUPTED) {
      return IsRecoverableInterrupted()
                 ? 2u | (item_->IsPaused() ? 4u : 0u)
                 : 0u;
    }
    if (item_->GetState() != download::DownloadItem::IN_PROGRESS) {
      return 0;
    }
    if (item_->IsPaused()) {
      return 4u | (item_->CanResume() ? 2u : 0u);
    }
    return 1u;
  }

  bool SetPaused(bool paused) {
    const uint32_t state = ControlState();
    if (paused ? !(state & 1u) : !(state & 2u)) {
      return false;
    }
    if (paused) {
      item_->Pause();
    } else {
      item_->Resume(true);
    }
    // Pause()/Resume() synchronously notify observers and may reenter a client
    // that releases this bridge. The validated pre-call state is the operation
    // acceptance result; later callbacks report the resulting transfer state.
    return true;
  }

  void Release() {
    DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
    const bool interrupted =
        item_ && item_->GetState() == download::DownloadItem::INTERRUPTED;
    client_released_ = true;
    if (confirmation_callback_ || interrupted) {
      Cancel(nullptr, nullptr);
      return;
    }
    MaybeDelete();
  }

  void OnDownloadUpdated(download::DownloadItem* item) override {
    DCHECK_EQ(item_, item);
    if (terminal_scheduled_) {
      return;
    }
    switch (item->GetState()) {
      case download::DownloadItem::COMPLETE:
        if (item->IsDangerous() || item->IsInsecure()) {
          RejectAfterObserverReturns(FailureMessage(item));
          return;
        }
        terminal_scheduled_ = true;
        terminal_status_ = CCS_DOWNLOAD_COMPLETE;
        QueueFileBarrier();
        return;
      case download::DownloadItem::CANCELLED:
        terminal_scheduled_ = true;
        terminal_status_ = CCS_DOWNLOAD_CANCELLED;
        QueueFileBarrier();
        return;
      case download::DownloadItem::INTERRUPTED:
        if (IsRecoverableInterrupted()) {
          SendRecoverableFailure();
          return;
        }
        RejectAfterObserverReturns(FailureMessage(item));
        return;
      case download::DownloadItem::IN_PROGRESS:
        interruption_reported_ = false;
        if (item->IsDangerous() || item->IsInsecure()) {
          RejectAfterObserverReturns(FailureMessage(item));
          return;
        }
        SendProgress();
        return;
      case download::DownloadItem::MAX_DOWNLOAD_STATE:
        return;
    }
  }

  void OnDownloadDestroyed(download::DownloadItem* item) override {
    DCHECK_EQ(item_, item);
    item_ = nullptr;
    confirmation_callback_.Reset();
    if (!terminal_scheduled_) {
      terminal_scheduled_ = true;
      terminal_status_ = CCS_DOWNLOAD_FAILED;
      terminal_error_ = "Chromium stopped before the download completed.";
      QueueFileBarrier();
    }
  }

 private:
  bool IsRecoverableInterrupted() const {
    return item_ && item_->GetState() == download::DownloadItem::INTERRUPTED &&
           accepted_destination_ && !confirmation_callback_ &&
           !destination_validation_pending_ &&
           item_->GetOriginalUrl().SchemeIsHTTPOrHTTPS() &&
           item_->GetURL().SchemeIsHTTPOrHTTPS() &&
           item_->WasCreatedFromGET() && item_->CanResume() &&
           !item_->IsDangerous() && !item_->IsInsecure();
  }

  void SendRecoverableFailure() {
    if (client_released_ || interruption_reported_) {
      return;
    }
    interruption_reported_ = true;
    terminal_error_ = FailureMessage(item_);
    SendState(CCS_DOWNLOAD_FAILED, terminal_error_.c_str());
    MaybeDelete();
  }

  void FinishDestinationValidation(const base::FilePath& staging_path,
                                   bool is_new_entry) {
    destination_validation_pending_ = false;
    if (!confirmation_callback_) {
      return;
    }
    auto callback = std::move(confirmation_callback_);
    confirmation_callback_.Reset();
    accepted_destination_ = is_new_entry;
    std::move(callback).Run(
        is_new_entry ? DownloadConfirmationResult::CONFIRMED
                     : DownloadConfirmationResult::CANCELED,
        is_new_entry ? ui::SelectedFileInfo(staging_path)
                     : ui::SelectedFileInfo());
  }

  void SendProgress() {
    if (client_released_ || !item_) {
      return;
    }
    SendState(CCS_DOWNLOAD_IN_PROGRESS);
    MaybeDelete();
  }

  void RejectAfterObserverReturns(std::string error) {
    terminal_scheduled_ = true;
    terminal_status_ = CCS_DOWNLOAD_FAILED;
    terminal_error_ = std::move(error);
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&CCSDownload::CancelRejectedDownload,
                                  weak_factory_.GetWeakPtr()));
  }

  void CancelRejectedDownload() {
    if (item_ && item_->GetState() != download::DownloadItem::COMPLETE &&
        item_->GetState() != download::DownloadItem::CANCELLED) {
      item_->Cancel(true);
    }
    QueueFileBarrier();
  }

  void ResolveDestinationAsCancelled() {
    if (!confirmation_callback_) {
      return;
    }
    auto callback = std::move(confirmation_callback_);
    confirmation_callback_.Reset();
    std::move(callback).Run(DownloadConfirmationResult::CANCELED,
                            ui::SelectedFileInfo());
  }

  void QueueFileBarrier() {
    // ponytail: if shutdown rejects this barrier, retain ownership until process
    // teardown. A fabricated completion would authorize deleting a staging file
    // while the download sequence may still be writing it. Runtime shutdown
    // invalidates the Swift handle without claiming file-sequence quiescence.
    download::GetDownloadTaskRunner()->PostTaskAndReply(
        FROM_HERE, base::DoNothing(),
        base::BindOnce(&CCSDownload::DeliverTerminalState,
                       weak_factory_.GetWeakPtr()));
  }

  void DeliverTerminalState() {
    if (terminal_delivered_) {
      return;
    }
    terminal_delivered_ = true;
    CompleteCancelRequests();
    if (!client_released_ && !(explicit_cancel_ &&
                               terminal_status_ == CCS_DOWNLOAD_CANCELLED)) {
      SendState(terminal_status_, terminal_status_ == CCS_DOWNLOAD_FAILED
                                      ? terminal_error_.c_str() : nullptr);
    }
    MaybeDelete();
  }

  void SendState(CCSDownloadStatus status, const char* error = nullptr) {
    // Local copies keep borrowed wire strings stable even if the client
    // synchronously resumes, cancels or releases the download in its callback.
    const std::string original = item_ ? item_->GetOriginalUrl().spec() : "";
    const std::string current = item_ ? item_->GetURL().spec() : "";
    const std::string mime = item_ ? item_->GetMimeType() : "";
    const std::string message = error ? error : "";
    const CCSDownloadStateV2 state = {
        .struct_size = sizeof(CCSDownloadStateV2),
        .received_bytes = item_ ? item_->GetReceivedBytes() : 0,
        .total_bytes = item_ ? item_->GetTotalBytes() : 0,
        .status = status,
        .error_utf8 = message.empty() ? nullptr : message.c_str(),
        .original_url_utf8 = original.c_str(),
        .current_url_utf8 = current.c_str(),
        .mime_type_utf8 = mime.c_str(),
        .interrupt_reason = status == CCS_DOWNLOAD_FAILED && item_
                                ? static_cast<int32_t>(item_->GetLastReason()) : 0,
    };
    base::AutoReset<bool> callback_guard(&in_client_callback_, true);
    cobble_chromium::NotifyDownloadStateChanged(this, &state);
  }

  void CompleteCancelRequests() {
    // Restore the outer callback's guard after nested AppKit event processing.
    // A plain false assignment would let DeleteSoon retire an active frame.
    base::AutoReset<bool> callback_guard(&in_client_callback_, true);
    auto requests = std::move(cancel_requests_);
    cancel_requests_.clear();
    for (auto& request : requests) {
      request->Complete();
    }
  }

  void MaybeDelete() {
    if (!client_released_ || !terminal_delivered_ || in_client_callback_ ||
        delete_scheduled_) {
      return;
    }
    delete_scheduled_ = true;
    if (item_) {
      item_->RemoveObserver(this);
      item_ = nullptr;
    }
    base::SingleThreadTaskRunner::GetCurrentDefault()->DeleteSoon(FROM_HERE,
                                                                   this);
  }

  raw_ptr<download::DownloadItem> item_ = nullptr;
  raw_ptr<Profile> private_profile_ = nullptr;
  std::unique_ptr<ScopedProfileKeepAlive> profile_keep_alive_;
  DownloadTargetDeterminerDelegate::ConfirmationCallback confirmation_callback_;
  std::vector<std::unique_ptr<CancelRequest>> cancel_requests_;
  CCSDownloadStatus terminal_status_ = CCS_DOWNLOAD_FAILED;
  std::string terminal_error_;
  bool explicit_cancel_ = false;
  bool terminal_scheduled_ = false;
  bool terminal_delivered_ = false;
  bool client_released_ = false;
  bool in_client_callback_ = false;
  bool delete_scheduled_ = false;
  bool destination_validation_pending_ = false;
  bool accepted_destination_ = false;
  bool interruption_reported_ = false;
  bool requires_private_profile_lease_ = false;
  bool has_private_profile_lease_ = false;
  base::WeakPtrFactory<CCSDownload> weak_factory_{this};
};

namespace cobble_chromium {

bool HasPendingDownloadWork(Profile* profile) {
  return std::ranges::any_of(Downloads(), [profile](CCSDownload* download) {
    return download && download->HasPendingWorkFor(profile);
  });
}

bool RequestDownloadDestination(
    download::DownloadItem* item,
    const base::FilePath& suggested_path,
    DownloadTargetDeterminerDelegate::ConfirmationCallback* callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!IsEnabled() || !callback) {
    return false;
  }
  auto* download = new CCSDownload(item, std::move(*callback));
  if (!download->IsReady()) {
    download->RejectWithoutClient();
    return true;
  }
  download->NotifyCreated(suggested_path);
  return true;
}

}  // namespace cobble_chromium

extern "C" void CCSDownloadSetDestination(CCSDownloadRef download,
                                           const char* staging_path_utf8) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (download && std::ranges::find(Downloads(), download) != Downloads().end()) {
    download->SetDestination(staging_path_utf8);
  }
}

extern "C" void CCSDownloadCancel(CCSDownloadRef download,
                                   void* callback_data,
                                   CCSDownloadCancelCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (download && std::ranges::find(Downloads(), download) != Downloads().end()) {
    download->Cancel(callback_data, callback);
  } else if (callback) {
    callback(callback_data);
  }
}

extern "C" void CCSDownloadRelease(CCSDownloadRef download) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (download && std::ranges::find(Downloads(), download) != Downloads().end()) {
    download->Release();
  }
}

extern "C" uint32_t CCSDownloadGetControlState(CCSDownloadRef download) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return download && std::ranges::find(Downloads(), download) != Downloads().end()
             ? download->ControlState()
             : 0;
}

extern "C" uint8_t CCSDownloadSetPaused(CCSDownloadRef download, uint8_t paused) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return download && paused <= 1 &&
         std::ranges::find(Downloads(), download) != Downloads().end() &&
         download->SetPaused(paused != 0);
}
