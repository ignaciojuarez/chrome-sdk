#ifndef CCS_LOADER_H
#define CCS_LOADER_H

// The Chromium overlay is the canonical ABI definition. SwiftPM ships source;
// the versioned framework, helpers, and resources are packaged separately.
#include "../../../chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.h"
#include "../../../chromium/overlay/chrome/browser/ui/cobble/cobble_extensions.h"
#include "../../../chromium/overlay/chrome/browser/ui/cobble/cobble_profile_deletion.h"
#include "../../../chromium/overlay/chrome/browser/ui/cobble/cobble_website_data.h"

typedef struct CCSAPI {
  uint8_t (*get_runtime_info)(CCSRuntimeInfoV1*);
  int32_t (*set_client)(const CCSClientV13*);
  void (*request_quit)(uint8_t);
  void (*cancel_quit)(void);
  CCSContextRef (*default_context)(void);
  CCSContextRef (*private_context)(void);
  void (*context_open)(const char*, const char*, void*, CCSContextOpenedCallback);
  void (*context_release)(CCSContextRef);
  void (*context_set_identity_resolver)(CCSContextRef, void*, CCSIdentityResolver);
  CCSPageRef (*page_create)(CCSContextRef, const char*, const char*);
  void* (*page_view)(CCSPageRef);
  void (*page_load_url)(CCSPageRef, const char*);
  void (*page_go_back)(CCSPageRef);
  void (*page_go_forward)(CCSPageRef);
  void (*page_copy_navigation_history_json)(CCSPageRef, void*, CCSPageDataCallback);
  uint8_t (*page_go_to_history_entry)(CCSPageRef, int32_t);
  uint8_t (*page_reload)(CCSPageRef);
  uint8_t (*page_reload_from_origin)(CCSPageRef);
  void (*page_stop)(CCSPageRef);
  void (*page_focus)(CCSPageRef);
  void (*page_set_visible)(CCSPageRef, uint8_t);
  uint8_t (*page_move_to_host)(CCSPageRef, const char*);
  int32_t (*page_find)(CCSPageRef, const char*, uint8_t);
  int32_t (*page_find_with_options)(CCSPageRef, const char*, uint32_t);
  void (*page_copy_initial_find_text)(CCSPageRef, void*, CCSPageDataCallback);
  double (*page_get_zoom_factor)(CCSPageRef);
  uint8_t (*page_set_zoom_factor)(CCSPageRef, double);
  uint8_t (*page_print)(CCSPageRef);
  void (*page_capture_viewport_png)(CCSPageRef, void*, CCSPageDataCallback);
  void (*page_current_dom)(CCSPageRef, void*, CCSPageDataCallback);
  void (*page_create_mhtml_archive)(CCSPageRef, void*, CCSPageDataCallback);
  void (*page_copy_connection_details_json)(CCSPageRef, void*, CCSPageDataCallback);
  void (*page_open_local_file)(CCSPageRef, const char*, void*, CCSPageDataCallback);
  uint8_t (*page_set_audio_muted)(CCSPageRef, uint8_t);
  uint8_t (*page_is_audio_muted)(CCSPageRef);
  uint8_t (*page_stop_media_capture)(CCSPageRef);
  void (*page_close)(CCSPageRef);
  void (*page_force_close)(CCSPageRef);
  uint8_t (*page_is_closed)(CCSPageRef);
  void (*page_release)(CCSPageRef);
  CCSDevToolsSessionRef (*page_open_devtools)(CCSPageRef, const char*);
  void* (*devtools_session_view)(CCSDevToolsSessionRef);
  void (*devtools_session_focus)(CCSDevToolsSessionRef);
  void (*devtools_session_set_visible)(CCSDevToolsSessionRef, uint8_t);
  uint8_t (*devtools_session_close)(CCSDevToolsSessionRef);
  uint8_t (*devtools_session_is_closed)(CCSDevToolsSessionRef);
  void (*devtools_session_release)(CCSDevToolsSessionRef);
  uint8_t (*media_permission_resolve)(CCSMediaPermissionRequestRef, uint8_t);
  uint8_t (*javascript_dialog_resolve)(CCSJavaScriptDialogRequestRef, uint8_t,
                                       const char*);
  uint8_t (*http_auth_resolve)(CCSHTTPAuthRequestRef, const char*, const char*);
  uint8_t (*http_auth_cancel)(CCSHTTPAuthRequestRef);
  uint8_t (*file_chooser_resolve)(CCSFileChooserRequestRef,
                                  const char* const*, size_t);
  uint8_t (*external_protocol_resolve)(CCSExternalProtocolRequestRef, uint8_t);
  uint8_t (*client_certificate_select)(CCSClientCertificateRequestRef, uint64_t);
  uint8_t (*client_certificate_cancel)(CCSClientCertificateRequestRef);
  uint8_t (*extension_install_resolve)(CCSExtensionInstallRequestRef, uint8_t);
  void (*download_set_destination)(CCSDownloadRef, const char*);
  void (*download_cancel)(CCSDownloadRef, void*, CCSDownloadCancelCallback);
  uint32_t (*download_get_control_state)(CCSDownloadRef);
  uint8_t (*download_set_paused)(CCSDownloadRef, uint8_t);
  void (*download_release)(CCSDownloadRef);
  void (*profile_deletion_preflight)(const char*, void*, CCSProfileDeleteCallback);
  void (*schedule_profile_deletion)(const char*, void*, CCSProfileDeleteCallback);
  void (*extension_list)(CCSContextRef, void*, CCSExtensionStringCallback);
  void (*extension_observe)(CCSContextRef, void*, CCSExtensionChangedCallback);
  void (*extension_install_unpacked)(CCSContextRef, const char*, void*, CCSExtensionStringCallback);
  void (*extension_set_enabled)(CCSContextRef, const char*, uint8_t, void*, CCSExtensionStringCallback);
  void (*extension_remove)(CCSContextRef, const char*, void*, CCSExtensionStringCallback);
  void (*extension_set_site_access)(CCSContextRef, const char*, const char*, uint8_t, void*, CCSExtensionStringCallback);
  void (*extension_perform_action)(CCSContextRef, CCSPageRef, const char*, void*, CCSExtensionStringCallback);
  void (*website_data_clear_cache)(CCSContextRef, void*, CCSWebsiteDataStringCallback);
  void (*website_data_list_sites)(CCSContextRef, void*, CCSWebsiteDataStringCallback);
  void (*website_data_remove_site)(CCSContextRef, const char*, void*, CCSWebsiteDataStringCallback);
  void (*website_data_remove)(CCSContextRef, const CCSWebsiteDataRemovalV1*,
                              void*, CCSWebsiteDataStringCallback);
  void (*cookies_export)(CCSContextRef, const char*, void*, CCSWebsiteDataStringCallback);
  void (*cookies_replace)(CCSContextRef, const char*, const char*, void*, CCSWebsiteDataStringCallback);
} CCSAPI;

// Resolve only the already loaded framework handle supplied to CCSClientMain
// by the SDK launcher. The launcher owns it until process exit. This API never
// loads an arbitrary path and never dlclose's Chromium.
int32_t CCSLoadAPIFromHandle(void* framework_handle, CCSAPI* api, char* error, size_t error_capacity);

#endif
