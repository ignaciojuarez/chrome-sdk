// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_DOWNLOADS_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_DOWNLOADS_H_

#include "base/files/file_path.h"
#include "chrome/browser/download/download_target_determiner.h"

namespace download {
class DownloadItem;
}

class Profile;

namespace cobble_chromium {

// Takes over Chrome's existing target confirmation stage. Returns false when
// the SDK bridge is disabled so Chrome can continue with its native picker.
bool RequestDownloadDestination(
    download::DownloadItem* item,
    const base::FilePath& suggested_path,
    DownloadTargetDeterminerDelegate::ConfirmationCallback* callback);
bool HasPendingDownloadWork(Profile* profile);

}  // namespace cobble_chromium

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_DOWNLOADS_H_
