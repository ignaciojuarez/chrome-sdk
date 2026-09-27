// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSION_INSTALL_PROMPT_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSION_INSTALL_PROMPT_H_

#include <memory>

#include "chrome/browser/extensions/extension_install_prompt.h"

class ExtensionInstallPromptShowParams;

namespace extensions {
class InstallPromptData;
}

namespace content {
class WebContents;
}

namespace cobble_chromium {

void ShowExtensionInstallPrompt(
    std::unique_ptr<ExtensionInstallPromptShowParams> show_params,
    ExtensionInstallPrompt::DoneCallback callback,
    std::unique_ptr<extensions::InstallPromptData> prompt);
bool PageHasPendingExtensionInstallPrompt(content::WebContents* contents);
void CancelExtensionInstallPromptsForPage(content::WebContents* contents);

}  // namespace cobble_chromium

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSION_INSTALL_PROMPT_H_
