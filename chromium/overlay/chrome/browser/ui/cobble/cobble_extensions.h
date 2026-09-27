// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSIONS_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSIONS_H_

#include "cobble_chromium.h"

#if defined(__cplusplus)
class Profile;
#endif

#if defined(__cplusplus)
extern "C" {
#endif

// Exactly one callback string is non-null. Its storage is valid only during
// the callback. Install may complete asynchronously; retain callback_data.
typedef void (*CCSExtensionStringCallback)(void* callback_data,
                                           const char* value_utf8,
                                           const char* error_utf8);
typedef void (*CCSExtensionChangedCallback)(void* callback_data);

// One observer per context. Passing null unregisters it; context release also
// unregisters before the callback data can be released by the client.
CCS_EXPORT void CCSExtensionObserve(CCSContextRef context,
                                    void* callback_data,
                                    CCSExtensionChangedCallback callback);

// Private contexts are rejected: they never expose normal-profile extensions.
CCS_EXPORT void CCSExtensionList(CCSContextRef context,
                      void* callback_data,
                      CCSExtensionStringCallback callback);
CCS_EXPORT void CCSExtensionInstallUnpacked(CCSContextRef context,
                                 const char* source_dir_utf8,
                                 void* callback_data,
                                 CCSExtensionStringCallback callback);
CCS_EXPORT void CCSExtensionSetEnabled(CCSContextRef context,
                            const char* extension_id_utf8,
                            uint8_t enabled,
                            void* callback_data,
                            CCSExtensionStringCallback callback);
CCS_EXPORT void CCSExtensionRemove(CCSContextRef context,
                        const char* extension_id_utf8,
                        void* callback_data,
                        CCSExtensionStringCallback callback);
// `origin_utf8` must be an http(s) URL. This is the only API that changes
// persistent host access for an installed extension.
CCS_EXPORT void CCSExtensionSetSiteAccess(CCSContextRef context,
                               const char* extension_id_utf8,
                               const char* origin_utf8,
                               uint8_t allowed,
                               void* callback_data,
                               CCSExtensionStringCallback callback);

// The page must belong to context. Popup and side-panel actions return an
// error until Cobble implements a native extension surface.
CCS_EXPORT void CCSExtensionPerformAction(CCSContextRef context,
                               CCSPageRef page,
                               const char* extension_id_utf8,
                               void* callback_data,
                               CCSExtensionStringCallback callback);

#if defined(__cplusplus)
}  // extern "C"

namespace cobble_chromium {

bool HasPendingExtensionWork(Profile* profile);
void ClearExtensionObservation(CCSContextRef context);

}  // namespace cobble_chromium
#endif

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_EXTENSIONS_H_
