// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_IDENTITY_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_IDENTITY_H_

#include "chrome/browser/ui/cobble/cobble_chromium.h"

namespace content {
class WebContents;
}

namespace cobble_chromium {

void AttachIdentityPolicy(CCSContextRef context, content::WebContents* contents);
void InheritIdentityPolicy(content::WebContents* opener,
                           content::WebContents* popup);
void ClearContextIdentityPolicy(CCSContextRef context);

}  // namespace cobble_chromium

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_IDENTITY_H_
