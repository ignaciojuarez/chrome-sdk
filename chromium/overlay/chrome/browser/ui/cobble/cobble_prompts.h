// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_PROMPTS_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_PROMPTS_H_

#include <memory>
#include <optional>
#include <stdint.h>

#include "base/functional/callback_forward.h"
#include "base/memory/scoped_refptr.h"
#include "content/public/browser/global_request_id.h"
#include "content/public/browser/login_delegate.h"
#include "url/origin.h"

class GURL;

namespace blink::mojom {
class FileChooserParams;
}

namespace content {
class FileSelectListener;
class JavaScriptDialogManager;
class RenderFrameHost;
class WebContents;
}

namespace net {
class AuthChallengeInfo;
}

namespace cobble_chromium {

content::JavaScriptDialogManager* GetJavaScriptDialogManager();
std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    const content::GlobalRequestID& request_id,
    bool primary_main_frame_navigation,
    bool navigation,
    const GURL& url,
    bool first_auth_attempt,
    content::LoginDelegate::LoginAuthRequiredCallback callback);
bool HandleFileChooser(content::RenderFrameHost* frame,
                       scoped_refptr<content::FileSelectListener> listener,
                       const blink::mojom::FileChooserParams& params);
uint64_t RequestFormRepostConfirmation(
    content::WebContents* contents,
    content::RenderFrameHost* frame,
    base::OnceCallback<void(bool)> callback);
void CancelFormRepostConfirmation(uint64_t request_id);
void HandleExternalProtocol(content::WebContents* contents,
                            content::RenderFrameHost* initiator,
                            const GURL& target_url,
                            const std::optional<url::Origin>& initiating_origin,
                            bool user_gesture,
                            bool primary_main_frame,
                            bool fenced_frame);
bool PageHasPendingPrompt(content::WebContents* contents);
void CancelPagePrompts(content::WebContents* contents,
                       bool cancel_extension_install = true);

}  // namespace cobble_chromium

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_PROMPTS_H_
