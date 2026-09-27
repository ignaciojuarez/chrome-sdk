// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_LOCAL_FILE_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_LOCAL_FILE_H_

#include <string>

#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "content/public/browser/frame_tree_node_id.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "services/network/public/mojom/url_loader_factory.mojom-forward.h"

namespace content {
class BrowserContext;
class NavigationHandle;
class NavigationThrottleRegistry;
class WebContents;
} // namespace content

namespace cobble_chromium {

void OpenLocalFile(CCSPageRef page, const char *url_utf8, void *callback_data,
                   CCSPageDataCallback callback);
bool IsLocalFileActive(CCSPageRef page);
bool CanNavigateLocalFileHistory(CCSPageRef page, int offset);
void LocalFileNavigationStarted(CCSPageRef page,
                                content::NavigationHandle *handle);
void LocalFileNavigationFinished(CCSPageRef page,
                                 content::NavigationHandle *handle);
void LocalFileBeforeUnloadCancelled(CCSPageRef page);
void LocalFileRenderProcessGone(CCSPageRef page);
void CloseLocalFileForPage(CCSPageRef page);
void AddLocalFileNavigationThrottle(
    content::NavigationThrottleRegistry &registry);
mojo::PendingRemote<network::mojom::URLLoaderFactory>
CreateLocalFileNavigationFactory(const std::string &scheme,
                                 content::FrameTreeNodeId frame_tree_node_id);
bool ShouldDenyLocalFileWorkerFactories(
    content::BrowserContext *browser_context);
bool ShouldDenyLocalFileSubresourceFactories(int render_process_id,
                                             int render_frame_id);
bool ShouldDenyLocalFileDownload(content::WebContents *contents,
                                 const GURL &url);

} // namespace cobble_chromium

#endif // CHROME_BROWSER_UI_COBBLE_COBBLE_LOCAL_FILE_H_
