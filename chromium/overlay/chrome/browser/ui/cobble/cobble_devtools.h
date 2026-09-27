// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_DEVTOOLS_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_DEVTOOLS_H_

#include "chrome/browser/ui/cobble/cobble_chromium.h"

class BrowserWindowInterface;
class Profile;

namespace content {
class JavaScriptDialogManager;
class WebContents;
}

namespace cobble_chromium {

bool IsOwnedDevTools(content::WebContents* contents);
bool HasPendingOwnedDevTools(content::WebContents* inspected);
BrowserWindowInterface* CreateOwnedDevToolsBrowser(
    Profile* profile,
    content::WebContents* inspected);
content::JavaScriptDialogManager* GetDevToolsJavaScriptDialogManager();
void CloseDevToolsForPage(CCSPageRef page);

}  // namespace cobble_chromium

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_DEVTOOLS_H_
