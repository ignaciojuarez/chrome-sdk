// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_PROFILE_DELETION_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_PROFILE_DELETION_H_

#include "cobble_chromium.h"

#if defined(__cplusplus)
extern "C" {
#endif

typedef enum CCSProfileDeleteStatus {
  CCS_PROFILE_DELETE_READY = 0,
  // The profile is no longer available to Chromium. Its directory is removed
  // at shutdown or a later startup; interrupted cleanup remains retryable.
  CCS_PROFILE_DELETE_LOGICAL_COMMIT = 1,
  CCS_PROFILE_DELETE_INVALID_KEY = 2,
  CCS_PROFILE_DELETE_NOT_FOUND = 3,
  CCS_PROFILE_DELETE_BUSY = 4,
  CCS_PROFILE_DELETE_FAILED = 5,
  // Chromium did not expose a terminal result in bounded time. Deletion can
  // still commit later; the profile remains fenced from reopening.
  CCS_PROFILE_DELETE_AMBIGUOUS = 6,
  // Profile and cache directories were verified absent after native shutdown.
  CCS_PROFILE_DELETE_COMPLETED = 7,
} CCSProfileDeleteStatus;

typedef void (*CCSProfileDeleteCallback)(void* callback_data,
                                         CCSProfileDeleteStatus status,
                                         const char* error_utf8);

// Schedules deletion of a named normal profile. Empty keys and the default
// profile are rejected. The callback may be asynchronous; its string is
// callback-scoped. ABI 5 success reports COMPLETED only after the native Profile
// has unloaded and both profile/cache directories are verified absent. An
// interrupted cleanup can be retried after restart, including an absent profile.
// Preflight allows app-owned contexts and pages that the caller will close,
// but rejects work that cannot be retired synchronously by the app.
CCS_EXPORT void CCSProfileDeletionPreflight(const char* profile_key_utf8,
                                            void* callback_data,
                                            CCSProfileDeleteCallback callback);
CCS_EXPORT void CCSScheduleProfileDeletion(const char* profile_key_utf8,
                                           void* callback_data,
                                           CCSProfileDeleteCallback callback);

#if defined(__cplusplus)
}  // extern "C"

namespace base {
class FilePath;
}

namespace cobble_chromium {

bool IsProfileDeletionPending(const base::FilePath& path);

}  // namespace cobble_chromium
#endif

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_PROFILE_DELETION_H_
