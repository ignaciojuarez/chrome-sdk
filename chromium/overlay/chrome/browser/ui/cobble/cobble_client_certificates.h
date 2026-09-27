// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only
#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_CLIENT_CERTIFICATES_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_CLIENT_CERTIFICATES_H_

#include <memory>

#include "base/functional/callback.h"
#include "net/ssl/client_cert_identity.h"

namespace content {
class ClientCertificateDelegate;
class NavigationOrDocumentHandle;
class WebContents;
}
namespace net {
class ClientCertStore;
class SSLCertRequestInfo;
}

namespace cobble_chromium {
base::OnceClosure HandleClientCertificateRequest(
    content::NavigationOrDocumentHandle* navigation_or_document,
    content::WebContents* contents,
    net::SSLCertRequestInfo* cert_request_info,
    net::ClientCertIdentityList identities,
    std::unique_ptr<content::ClientCertificateDelegate> delegate);
bool PageHasPendingClientCertificate(content::WebContents* contents);
void CancelClientCertificatesForPage(content::WebContents* contents);
std::unique_ptr<net::ClientCertStore>
CreateRestrictedClientCertStoreForFixture();
}
#endif
