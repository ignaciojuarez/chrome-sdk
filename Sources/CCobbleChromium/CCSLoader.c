#include "CCSLoader.h"
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static int32_t failure(char* error, size_t capacity, const char* message) {
  if (error && capacity) snprintf(error, capacity, "%s", message ? message : "Unknown loader error");
  return -1;
}

int32_t CCSLoadAPIFromHandle(void* library, CCSAPI* api, char* error, size_t capacity) {
  if (!library || !api)
    return failure(error, capacity, "The SDK launcher's framework handle is required");
  memset(api, 0, sizeof(*api));

#define RESOLVE(member, symbol) \
  do { \
    void* address = dlsym(library, symbol); \
    if (!address) { \
      memset(api, 0, sizeof(*api)); \
      return failure(error, capacity, "Chromium SDK export missing: " symbol); \
    } \
    memcpy(&api->member, &address, sizeof(address)); \
  } while (0)

  RESOLVE(set_client, "CCSSetClient");
  RESOLVE(request_quit, "CCSRequestQuit");
  RESOLVE(cancel_quit, "CCSCancelQuit");
  RESOLVE(default_context, "CCSDefaultContext");
  RESOLVE(private_context, "CCSPrivateContext");
  RESOLVE(context_open, "CCSContextOpen");
  RESOLVE(context_release, "CCSContextRelease");
  RESOLVE(context_set_identity_resolver, "CCSContextSetIdentityResolver");
  RESOLVE(page_create, "CCSPageCreate");
  RESOLVE(page_view, "CCSPageView");
  RESOLVE(page_load_url, "CCSPageLoadURL");
  RESOLVE(page_go_back, "CCSPageGoBack");
  RESOLVE(page_go_forward, "CCSPageGoForward");
  RESOLVE(page_reload, "CCSPageReload");
  RESOLVE(page_reload_from_origin, "CCSPageReloadFromOrigin");
  RESOLVE(page_stop, "CCSPageStop");
  RESOLVE(page_focus, "CCSPageFocus");
  RESOLVE(page_set_visible, "CCSPageSetVisible");
  RESOLVE(page_move_to_host, "CCSPageMoveToHost");
  RESOLVE(page_find, "CCSPageFind");
  RESOLVE(page_get_zoom_factor, "CCSPageGetZoomFactor");
  RESOLVE(page_set_zoom_factor, "CCSPageSetZoomFactor");
  RESOLVE(page_print, "CCSPagePrint");
  RESOLVE(page_capture_viewport_png, "CCSPageCaptureViewportPNG");
  RESOLVE(page_current_dom, "CCSPageCurrentDOM");
  RESOLVE(page_create_mhtml_archive, "CCSPageCreateMHTMLArchive");
  RESOLVE(page_copy_connection_details_json, "CCSPageCopyConnectionDetailsJSON");
  RESOLVE(page_open_local_file, "CCSPageOpenLocalFile");
  RESOLVE(page_set_audio_muted, "CCSPageSetAudioMuted");
  RESOLVE(page_is_audio_muted, "CCSPageIsAudioMuted");
  RESOLVE(page_stop_media_capture, "CCSPageStopMediaCapture");
  RESOLVE(page_close, "CCSPageClose");
  RESOLVE(page_force_close, "CCSPageForceClose");
  RESOLVE(page_is_closed, "CCSPageIsClosed");
  RESOLVE(page_release, "CCSPageRelease");
  RESOLVE(page_open_devtools, "CCSPageOpenDevTools");
  RESOLVE(devtools_session_view, "CCSDevToolsSessionView");
  RESOLVE(devtools_session_focus, "CCSDevToolsSessionFocus");
  RESOLVE(devtools_session_set_visible, "CCSDevToolsSessionSetVisible");
  RESOLVE(devtools_session_close, "CCSDevToolsSessionClose");
  RESOLVE(devtools_session_is_closed, "CCSDevToolsSessionIsClosed");
  RESOLVE(devtools_session_release, "CCSDevToolsSessionRelease");
  RESOLVE(media_permission_resolve, "CCSMediaPermissionResolve");
  RESOLVE(javascript_dialog_resolve, "CCSJavaScriptDialogResolve");
  RESOLVE(http_auth_resolve, "CCSHTTPAuthResolve");
  RESOLVE(http_auth_cancel, "CCSHTTPAuthCancel");
  RESOLVE(file_chooser_resolve, "CCSFileChooserResolve");
  RESOLVE(external_protocol_resolve, "CCSExternalProtocolResolve");
  RESOLVE(client_certificate_select, "CCSClientCertificateSelect");
  RESOLVE(client_certificate_cancel, "CCSClientCertificateCancel");
  RESOLVE(extension_install_resolve, "CCSExtensionInstallResolve");
  RESOLVE(download_set_destination, "CCSDownloadSetDestination");
  RESOLVE(download_cancel, "CCSDownloadCancel");
  RESOLVE(download_get_control_state, "CCSDownloadGetControlState");
  RESOLVE(download_set_paused, "CCSDownloadSetPaused");
  RESOLVE(download_release, "CCSDownloadRelease");
  RESOLVE(profile_deletion_preflight, "CCSProfileDeletionPreflight");
  RESOLVE(schedule_profile_deletion, "CCSScheduleProfileDeletion");
  RESOLVE(extension_list, "CCSExtensionList");
  RESOLVE(extension_observe, "CCSExtensionObserve");
  RESOLVE(extension_install_unpacked, "CCSExtensionInstallUnpacked");
  RESOLVE(extension_set_enabled, "CCSExtensionSetEnabled");
  RESOLVE(extension_remove, "CCSExtensionRemove");
  RESOLVE(extension_set_site_access, "CCSExtensionSetSiteAccess");
  RESOLVE(extension_perform_action, "CCSExtensionPerformAction");
  RESOLVE(website_data_clear_cache, "CCSWebsiteDataClearCache");
  RESOLVE(website_data_list_sites, "CCSWebsiteDataListSites");
  RESOLVE(website_data_remove_site, "CCSWebsiteDataRemoveSite");
  RESOLVE(website_data_remove, "CCSWebsiteDataRemove");
  RESOLVE(cookies_export, "CCSCookiesExport");
  RESOLVE(cookies_replace, "CCSCookiesReplace");
#undef RESOLVE
  return 0;
}
