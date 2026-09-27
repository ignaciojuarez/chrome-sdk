// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_profile_deletion.h"

#include <algorithm>
#include <cerrno>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <utility>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/file.h"
#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/location.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/time/time.h"
#include "base/task/thread_pool.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/common/chrome_paths_internal.h"
#include "base/timer/timer.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/delete_profile_helper.h"
#include "chrome/browser/profiles/nuke_profile_directory_utils.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "chrome/browser/profiles/profile_attributes_storage_observer.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_manager_observer.h"
#include "chrome/browser/profiles/profile_observer.h"
#include "chrome/browser/profiles/profile_metrics.h"
#include "chrome/browser/ui/cobble/cobble_downloads.h"
#include "chrome/browser/ui/cobble/cobble_extensions.h"
#include "chrome/browser/ui/cobble/cobble_website_data.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/download_manager.h"

namespace {

class PendingDeletion;
using PendingDeletions = std::vector<std::unique_ptr<PendingDeletion>>;

PendingDeletions& Deletions() {
  static base::NoDestructor<PendingDeletions> deletions;
  return *deletions;
}

bool HasPendingDeletion(const base::FilePath& path);

// Use lstat rather than PathExists: permission errors and dangling symlinks
// must never be mistaken for successful removal.
bool ProfileFilesAreAbsent(const base::FilePath& path) {
  base::FilePath cache;
  chrome::GetUserCacheDirectory(path, &cache);
  const auto absent = [](const base::FilePath& candidate) {
    base::stat_wrapper_t info;
    return base::File::Lstat(candidate, &info) != 0 && errno == ENOENT;
  };
  return absent(path) && absent(cache);
}

void Reply(CCSProfileDeleteCallback callback,
           void* callback_data,
           CCSProfileDeleteStatus status,
           const std::string& error) {
  if (callback) {
    callback(callback_data, status, error.empty() ? nullptr : error.c_str());
  }
}

bool HasActiveDownloads(Profile* profile) {
  if (!profile) {
    return false;
  }
  const auto active = [](Profile* candidate) {
    download::SimpleDownloadManager::DownloadVector downloads;
    candidate->GetDownloadManager()->GetAllDownloads(&downloads);
    return std::ranges::any_of(downloads, [](const auto& download) {
      return download &&
             download->GetState() == download::DownloadItem::IN_PROGRESS;
    });
  };
  if (active(profile)) {
    return true;
  }
  return std::ranges::any_of(profile->GetAllOffTheRecordProfiles(), active);
}

CCSProfileDeleteStatus Validate(const char* profile_key,
                                bool require_retired,
                                base::FilePath* path,
                                Profile** profile,
                                std::string* error) {
  if (!cobble_chromium::ResolveProfileKey(profile_key, path, profile, error)) {
    const std::string key = profile_key ? profile_key : "";
    return key.empty() || error->starts_with("Profile keys must")
               ? CCS_PROFILE_DELETE_INVALID_KEY
               : CCS_PROFILE_DELETE_FAILED;
  }
  if (cobble_chromium::HasPendingProfileOpen(*path)) {
    *error = "The Chromium profile is still opening";
    return CCS_PROFILE_DELETE_BUSY;
  }
  ProfileManager* manager = g_browser_process->profile_manager();
  if (HasPendingDeletion(*path)) {
    *error = "Chromium profile deletion is already in progress";
    return CCS_PROFILE_DELETE_BUSY;
  }
  if (require_retired && cobble_chromium::HasProfileBridgeWork(*path, *profile)) {
    *error = "The Chromium profile still has live contexts or pages";
    return CCS_PROFILE_DELETE_BUSY;
  }
  if (HasActiveDownloads(*profile) ||
      cobble_chromium::HasPendingDownloadWork(*profile) ||
      cobble_chromium::HasPendingExtensionWork(*profile) ||
      cobble_chromium::HasPendingWebsiteDataWork(*profile)) {
    *error = "The Chromium profile still has active data work";
    return CCS_PROFILE_DELETE_BUSY;
  }
  if (IsProfileDirectoryMarkedForDeletion(*path) ||
      !manager->GetProfileAttributesStorage().GetProfileAttributesWithPath(*path)) {
    // No normal registration remains. Deletion still verifies both directories
    // (or finishes a prior cleanup); preflight itself never mutates files.
    error->clear();
    return CCS_PROFILE_DELETE_NOT_FOUND;
  }
  error->clear();
  return CCS_PROFILE_DELETE_READY;
}

class PendingDeletion final : public ProfileAttributesStorage::Observer,
                              public ProfileManagerObserver,
                              public ProfileObserver {
 public:
  PendingDeletion(base::FilePath path,
                  void* callback_data,
                  CCSProfileDeleteCallback callback)
      : path_(std::move(path)),
        callback_data_(callback_data),
        callback_(callback) {
    auto* manager = g_browser_process->profile_manager();
    manager->GetProfileAttributesStorage().AddObserver(this);
    manager->AddObserver(this);
    ObserveProfile(manager->GetProfileByPath(path_));
  }

  ~PendingDeletion() override {
    if (observed_profile_) {
      observed_profile_->RemoveObserver(this);
    }
    g_browser_process->profile_manager()->RemoveObserver(this);
    g_browser_process->profile_manager()->GetProfileAttributesStorage().RemoveObserver(
        this);
  }

  const base::FilePath& path() const { return path_; }

  void StartTimeout() {
    timer_.Start(FROM_HERE, base::Seconds(30),
                 base::BindOnce(&PendingDeletion::ReportAmbiguous,
                                base::Unretained(this)));
  }

  void OnProfileWasRemoved(const base::FilePath& path,
                           const std::u16string&) override {
    if (path == path_) {
      RegistrationRemoved();
    }
  }

  void RegistrationRemoved() {
    registration_removed_ = true;
    BeginDiskCleanup();
  }

  void OnProfileMarkedForPermanentDeletion(Profile* profile) override {
    if (profile->GetPath() == path_) {
      ObserveProfile(profile);
    }
  }

  void OnProfileWillBeDestroyed(Profile* profile) override {
    CHECK_EQ(profile, observed_profile_);
    observed_profile_->RemoveObserver(this);
    observed_profile_ = nullptr;
    // ProfileManager can remove its lookup before ProfileDestroyer actually
    // destroys the object. Resume only after the destructor's UI task ends.
    base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&PendingDeletion::ProfileDestroyed,
                                  weak_factory_.GetWeakPtr()));
  }

  void BeginDiskCleanup() {
    if (!registration_removed_ || disk_cleanup_started_) {
      return;
    }
    // Chromium owns profile shutdown and all native data/extension leases.
    // Never remove a directory while a loaded Profile can still write to it.
    if (!profile_destroyed_ || observed_profile_ ||
        g_browser_process->profile_manager()->GetProfileByPath(path_)) {
      poll_timer_.Start(FROM_HERE, base::Milliseconds(250),
                       base::BindOnce(&PendingDeletion::BeginDiskCleanup,
                                      weak_factory_.GetWeakPtr()));
      return;
    }
    disk_cleanup_started_ = true;
    if (!base::ThreadPool::PostTask(
            FROM_HERE,
            {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
             base::TaskShutdownBehavior::SKIP_ON_SHUTDOWN},
            base::BindOnce(&NukeProfileFromDisk, path_,
                           base::BindOnce(&PendingDeletion::VerifyDiskCleanup,
                                          weak_factory_.GetWeakPtr())))) {
      Complete(CCS_PROFILE_DELETE_FAILED,
               "Chromium could not schedule profile disk cleanup; retry after restart");
    }
  }

  void Complete(CCSProfileDeleteStatus status, std::string error) {
    auto& deletions = Deletions();
    auto found = std::ranges::find_if(
        deletions, [this](const auto& deletion) { return deletion.get() == this; });
    if (found == deletions.end()) {
      return;
    }
    std::unique_ptr<PendingDeletion> lifetime = std::move(*found);
    deletions.erase(found);
    void* callback_data = callback_data_.get();
    callback_data_ = nullptr;
    Reply(callback_, callback_data, status, error);
  }

 private:
  void ObserveProfile(Profile* profile) {
    if (!profile || observed_profile_ == profile) {
      return;
    }
    CHECK(!observed_profile_);
    observed_profile_ = profile;
    profile_destroyed_ = false;
    profile->AddObserver(this);
  }

  void ProfileDestroyed() {
    profile_destroyed_ = true;
    BeginDiskCleanup();
  }

  void VerifyDiskCleanup() {
    if (!base::ThreadPool::PostTaskAndReplyWithResult(
            FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
            base::BindOnce(&ProfileFilesAreAbsent, path_),
            base::BindOnce(&PendingDeletion::DiskCleanupVerified,
                           weak_factory_.GetWeakPtr()))) {
      Complete(CCS_PROFILE_DELETE_FAILED,
               "Chromium could not verify profile disk cleanup; retry after restart");
    }
  }

  void DiskCleanupVerified(bool absent) {
    Complete(absent ? CCS_PROFILE_DELETE_COMPLETED : CCS_PROFILE_DELETE_FAILED,
             absent ? "" : "Some Chromium profile or cache files remain; retry deletion after restart");
  }

  void ReportAmbiguous() {
    CCSProfileDeleteCallback callback = std::exchange(callback_, nullptr);
    void* callback_data = callback_data_.get();
    callback_data_ = nullptr;
    Reply(callback, callback_data, CCS_PROFILE_DELETE_AMBIGUOUS,
          "Chromium did not confirm profile disk cleanup; it may still finish, so "
          "the profile remains unavailable until restart");
  }

  base::FilePath path_;
  raw_ptr<void> callback_data_ = nullptr;
  CCSProfileDeleteCallback callback_ = nullptr;
  base::OneShotTimer timer_;
  base::OneShotTimer poll_timer_;
  raw_ptr<Profile> observed_profile_ = nullptr;
  bool profile_destroyed_ = true;
  bool registration_removed_ = false;
  bool disk_cleanup_started_ = false;
  base::WeakPtrFactory<PendingDeletion> weak_factory_{this};
};

bool HasPendingDeletion(const base::FilePath& path) {
  return std::ranges::any_of(Deletions(), [&path](const auto& deletion) {
    return deletion && deletion->path() == path;
  });
}

void CancelPendingDeletionsForShutdown() {
  while (!Deletions().empty()) {
    Deletions().back()->Complete(
        CCS_PROFILE_DELETE_FAILED,
        "Chromium stopped before profile disk cleanup was verified; "
        "retry after restart");
  }
}

void EnsureShutdownCallback() {
  static bool registered = false;
  if (!registered) {
    cobble_chromium::RegisterShutdownCallback(
        &CancelPendingDeletionsForShutdown);
    registered = true;
  }
}

}  // namespace

namespace cobble_chromium {

bool IsProfileDeletionPending(const base::FilePath& path) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return HasPendingDeletion(path);
}

}  // namespace cobble_chromium

extern "C" void CCSProfileDeletionPreflight(
    const char* profile_key_utf8,
    void* callback_data,
    CCSProfileDeleteCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  base::FilePath path;
  Profile* profile = nullptr;
  std::string error;
  const CCSProfileDeleteStatus status =
      Validate(profile_key_utf8, false, &path, &profile, &error);
  Reply(callback, callback_data,
        status == CCS_PROFILE_DELETE_NOT_FOUND ? CCS_PROFILE_DELETE_READY : status,
        error);
}

extern "C" void CCSScheduleProfileDeletion(
    const char* profile_key_utf8,
    void* callback_data,
    CCSProfileDeleteCallback callback) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!callback) {
    return;
  }
  EnsureShutdownCallback();
  base::FilePath path;
  Profile* profile = nullptr;
  std::string error;
  const CCSProfileDeleteStatus status =
      Validate(profile_key_utf8, true, &path, &profile, &error);
  if (status != CCS_PROFILE_DELETE_READY && status != CCS_PROFILE_DELETE_NOT_FOUND) {
    Reply(callback, callback_data, status, error);
    return;
  }

  auto deletion =
      std::make_unique<PendingDeletion>(path, callback_data, callback);
  PendingDeletion* pending = deletion.get();
  Deletions().push_back(std::move(deletion));
  pending->StartTimeout();
  if (status == CCS_PROFILE_DELETE_NOT_FOUND) {
    pending->RegistrationRemoved();
    return;
  }
  g_browser_process->profile_manager()
      ->GetDeleteProfileHelper()
      .MaybeScheduleProfileForDeletion(
          path, base::DoNothing(), ProfileMetrics::DELETE_PROFILE_USER_MANAGER);
}
