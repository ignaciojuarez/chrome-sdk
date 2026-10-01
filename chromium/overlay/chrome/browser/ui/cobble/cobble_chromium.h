// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#ifndef CHROME_BROWSER_UI_COBBLE_COBBLE_CHROMIUM_H_
#define CHROME_BROWSER_UI_COBBLE_COBBLE_CHROMIUM_H_

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define CCS_ABI_VERSION 17u
// Chromium compiles with hidden visibility; the client resolves this ABI by name.
#define CCS_EXPORT __attribute__((visibility("default")))

typedef struct CCSContext* CCSContextRef;
typedef struct CCSPage* CCSPageRef;
typedef struct CCSDownload* CCSDownloadRef;
typedef struct CCSMediaPermissionRequest* CCSMediaPermissionRequestRef;
typedef struct CCSJavaScriptDialogRequest* CCSJavaScriptDialogRequestRef;
typedef struct CCSHTTPAuthRequest* CCSHTTPAuthRequestRef;
typedef struct CCSFileChooserRequest* CCSFileChooserRequestRef;
typedef struct CCSExternalProtocolRequest* CCSExternalProtocolRequestRef;
typedef struct CCSDevToolsSession* CCSDevToolsSessionRef;
typedef struct CCSClientCertificateRequest* CCSClientCertificateRequestRef;
typedef struct CCSExtensionInstallRequest* CCSExtensionInstallRequestRef;

// Synchronous on Chromium's UI thread. Return 0 for native identity, 1 for
// Android phone, 2 for Android tablet, 3 for iPhone, or 4 for iPad. URL storage
// belongs to Chromium and is valid only while the callback runs. Unknown values
// are treated as native identity.
typedef int32_t (*CCSIdentityResolver)(void* user_data, const char* url_utf8);

typedef enum CCSMediaPermissionKind {
  CCS_MEDIA_PERMISSION_MICROPHONE = 1 << 0,
  CCS_MEDIA_PERMISSION_CAMERA = 1 << 1,
} CCSMediaPermissionKind;

typedef struct CCSMediaPermissionRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  uint32_t kinds;
  const char* requesting_origin_utf8;
  const char* embedding_origin_utf8;
  int32_t frame_process_id;
  int32_t frame_routing_id;
  const char* frame_token_utf8;
  uint8_t user_gesture;
} CCSMediaPermissionRequestV1;

typedef struct CCSPopupRequestV1 {
  uint32_t struct_size;
  CCSPageRef opener;
  const char* opener_url_utf8;
  const char* top_level_url_utf8;
  const char* requesting_origin_utf8;
  const char* target_url_utf8;
  int32_t disposition;
  uint8_t user_gesture;
  uint8_t opener_suppressed;
} CCSPopupRequestV1;

typedef enum CCSJavaScriptDialogKind {
  CCS_JAVASCRIPT_DIALOG_ALERT = 0,
  CCS_JAVASCRIPT_DIALOG_CONFIRM = 1,
  CCS_JAVASCRIPT_DIALOG_PROMPT = 2,
  CCS_JAVASCRIPT_DIALOG_BEFORE_UNLOAD = 3,
  CCS_JAVASCRIPT_DIALOG_FORM_REPOST = 4,
} CCSJavaScriptDialogKind;

typedef struct CCSJavaScriptDialogRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  CCSJavaScriptDialogKind kind;
  const char* requesting_origin_utf8;
  const char* top_level_origin_utf8;
  int32_t frame_process_id;
  int32_t frame_routing_id;
  const char* frame_token_utf8;
  const char* message_utf8;
  const char* default_prompt_utf8;
  uint8_t is_reload;
} CCSJavaScriptDialogRequestV1;

typedef struct CCSHTTPAuthRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  const char* request_url_utf8;
  const char* challenger_origin_utf8;
  const char* top_level_origin_utf8;
  const char* scheme_utf8;
  const char* realm_utf8;
  const char* document_frame_token_utf8;
  int32_t network_process_id;
  int32_t network_request_id;
  uint8_t is_proxy;
  uint8_t first_attempt;
  uint8_t primary_main_frame_navigation;
  uint8_t navigation;
} CCSHTTPAuthRequestV1;

typedef enum CCSFileChooserMode {
  CCS_FILE_CHOOSER_OPEN = 0,
  CCS_FILE_CHOOSER_OPEN_MULTIPLE = 1,
  CCS_FILE_CHOOSER_UPLOAD_FOLDER = 2,
  CCS_FILE_CHOOSER_OPEN_DIRECTORY = 3,
  CCS_FILE_CHOOSER_SAVE = 4,
} CCSFileChooserMode;

typedef struct CCSFileChooserRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  CCSFileChooserMode mode;
  const char* requesting_origin_utf8;
  const char* top_level_origin_utf8;
  int32_t frame_process_id;
  int32_t frame_routing_id;
  const char* frame_token_utf8;
  const char* title_utf8;
  const char* default_filename_utf8;
  const char* const* accepted_types_utf8;
  size_t accepted_type_count;
} CCSFileChooserRequestV1;

typedef struct CCSExternalProtocolRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  const char* target_url_utf8;
  const char* requesting_origin_utf8;
  const char* top_level_origin_utf8;
  int32_t frame_process_id;
  int32_t frame_routing_id;
  const char* frame_token_utf8;
  uint8_t user_gesture;
  uint8_t primary_main_frame;
  uint8_t fenced_frame;
} CCSExternalProtocolRequestV1;

typedef enum CCSDownloadStatus {
  CCS_DOWNLOAD_IN_PROGRESS = 0,
  CCS_DOWNLOAD_COMPLETE = 1,
  CCS_DOWNLOAD_CANCELLED = 2,
  CCS_DOWNLOAD_FAILED = 3,
} CCSDownloadStatus;

typedef struct CCSDownloadStateV1 {
  uint32_t struct_size;
  int64_t received_bytes;
  int64_t total_bytes;
  CCSDownloadStatus status;
  // Present only for CCS_DOWNLOAD_FAILED and borrowed for this callback. A
  // failed update is recoverable only while CCSDownloadGetControlState returns
  // the can-resume bit; otherwise it is terminal.
  const char* error_utf8;
} CCSDownloadStateV1;

typedef enum CCSPageConnection {
  CCS_PAGE_CONNECTION_UNKNOWN = 0,
  CCS_PAGE_CONNECTION_EMPTY = 1,
  CCS_PAGE_CONNECTION_SECURE = 2,
  CCS_PAGE_CONNECTION_MIXED = 3,
  CCS_PAGE_CONNECTION_INSECURE = 4,
} CCSPageConnection;

typedef struct CCSFindResultV1 {
  uint32_t struct_size;
  int32_t request_id;
  int32_t match_count;
  int32_t active_match_ordinal;
  uint8_t final_update;
} CCSFindResultV1;

typedef struct CCSClientCertificateChoiceV1 {
  uint32_t struct_size;
  uint64_t choice_id;
  const char* subject_utf8;
  const char* issuer_utf8;
  // Uppercase hexadecimal with DER INTEGER sign-padding zero octets removed.
  const char* serial_utf8;
  int64_t valid_from_unix_seconds;
  int64_t valid_until_unix_seconds;
} CCSClientCertificateChoiceV1;

typedef struct CCSClientCertificateRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  const char* challenger_origin_utf8;
  const char* top_level_origin_utf8;
  const char* visible_page_origin_utf8;
  uint8_t is_navigation;
  int64_t navigation_id;
  int32_t frame_process_id;
  int32_t frame_routing_id;
  const char* frame_token_utf8;
  uint8_t primary_main_frame;
  const CCSClientCertificateChoiceV1* choices;
  size_t choice_count;
  uint8_t choices_truncated;
} CCSClientCertificateRequestV1;

typedef struct CCSExtensionInstallRequestV1 {
  uint32_t struct_size;
  uint64_t request_id;
  const char* extension_id_utf8;
  const char* name_utf8;
  const char* source_url_utf8;
  const char* title_utf8;
  const char* permissions_heading_utf8;
  const char* const* permission_warnings_utf8;
  size_t permission_warning_count;
  uint8_t can_withhold_host_permissions;
  uint8_t requests_host_permissions;
} CCSExtensionInstallRequestV1;

typedef struct CCSPageStateV4 {
  uint32_t struct_size;
  const char* url_utf8;
  const char* title_utf8;
  uint8_t loading;
  uint8_t can_go_back;
  uint8_t can_go_forward;
  uint8_t crashed;
  uint8_t audible;
  uint8_t audio_muted;
  CCSPageConnection connection;
  uint8_t security_error_page;
  uint8_t security_certificate_error;
  uint8_t security_displayed_mixed_content;
  uint8_t security_ran_mixed_content;
  uint8_t capturing_microphone;
  uint8_t capturing_camera;
  // Borrowed only for page_state_changed. Oversized or unavailable values are
  // represented by a null pointer and zero length.
  const uint8_t* favicon_png;
  size_t favicon_png_size;
  const char* hovered_link_utf8;
  uint8_t has_pending_prompt;
} CCSPageStateV4;

typedef struct CCSClientV12 {
  uint32_t abi_version;
  uint32_t struct_size;
  void* user_data;
  // Runs after Chromium has created its macOS application and browser threads.
  // AppKit UI may be created, but profiles and page APIs are not ready yet.
  void (*runtime_ui_ready)(void* user_data);
  void (*runtime_ready)(void* user_data);
  void (*runtime_will_stop)(void* user_data);
  void (*page_state_changed)(void* user_data,
                             CCSPageRef page,
                             const CCSPageStateV4* state);
  void (*page_closed)(void* user_data, CCSPageRef page);
  void (*popup_created)(void* user_data,
                        CCSPageRef opener,
                        CCSPageRef popup,
                        const char* host_window_id_utf8);
  // Returns an unretained NSWindow*. `page` can be null during early startup.
  void* (*host_window)(void* user_data,
                       const char* host_window_id_utf8,
                       CCSPageRef page);
  // Chromium changed the active tab in a grouped Browser.
  void (*page_activated)(void* user_data, CCSPageRef page);
  // AppController events may arrive before runtime_ready. AppKit UI is safe
  // after runtime_ui_ready, but profile and page work must await runtime_ready.
  void (*app_quit_requested)(void* user_data, uint8_t system_shutdown);
  void (*app_reopen)(void* user_data);
  void (*app_open_urls)(void* user_data,
                        const char* const* urls_utf8,
                        size_t url_count);
  // An explicit CCSPageClose was refused. The page remains valid and can be
  // closed again after the client has restored its UI state.
  void (*page_close_cancelled)(void* user_data, CCSPageRef page);
  // Reports successful primary-main-frame commits. A cross-document callback
  // waits for loading to settle so its title belongs to the committed document,
  // unless a same-document or new navigation flushes it first. Closing the page
  // discards an unfinished pending visit. String storage is valid only for the
  // callback.
  void (*page_navigation_committed)(void* user_data,
                                    CCSPageRef page,
                                    const char* url_utf8,
                                    const char* title_utf8);
  // Reports a successful primary-main-frame commit immediately. Unlike
  // page_navigation_committed, this does not wait for a settled title.
  void (*page_primary_main_frame_committed)(void* user_data,
                                            CCSPageRef page,
                                            const char* url_utf8);
  // Chromium's asynchronous find reply. Match counts and ordinals are the
  // native result for request_id; they are never synthesized by the bridge.
  void (*page_find_result)(void* user_data,
                           CCSPageRef page,
                           const CCSFindResultV1* result);
  // Download handles are client-owned after this callback until
  // CCSDownloadRelease or runtime_will_stop. `page` and string storage are
  // borrowed. Runtime shutdown is not a file-sequence completion signal.
  void (*download_created)(void* user_data,
                           CCSPageRef page,
                           CCSDownloadRef download,
                           const char* suggested_filename_utf8);
  void (*download_state_changed)(void* user_data,
                                 CCSDownloadRef download,
                                 const CCSDownloadStateV1* state);
  // Return nonzero to permit creation. Missing callbacks deny before Chromium
  // allocates a child WebContents.
  uint8_t (*popup_requested)(void* user_data,
                             const CCSPopupRequestV1* request);
  // Request and string storage are borrowed for this callback. The opaque
  // request stays valid until it is resolved or media_permission_cancelled.
  void (*media_permission_requested)(
      void* user_data,
      CCSPageRef page,
      CCSMediaPermissionRequestRef request,
      const CCSMediaPermissionRequestV1* state);
  void (*media_permission_cancelled)(void* user_data,
                                     CCSMediaPermissionRequestRef request,
                                     uint64_t request_id);
  void (*javascript_dialog_requested)(
      void* user_data,
      CCSPageRef page,
      CCSJavaScriptDialogRequestRef request,
      const CCSJavaScriptDialogRequestV1* state);
  void (*javascript_dialog_cancelled)(void* user_data,
                                      CCSJavaScriptDialogRequestRef request,
                                      uint64_t request_id);
  void (*http_auth_requested)(void* user_data,
                              CCSPageRef page,
                              CCSHTTPAuthRequestRef request,
                              const CCSHTTPAuthRequestV1* state);
  void (*http_auth_cancelled)(void* user_data,
                              CCSHTTPAuthRequestRef request,
                              uint64_t request_id);
  void (*file_chooser_requested)(void* user_data,
                                 CCSPageRef page,
                                 CCSFileChooserRequestRef request,
                                 const CCSFileChooserRequestV1* state);
  void (*file_chooser_cancelled)(void* user_data,
                                 CCSFileChooserRequestRef request,
                                 uint64_t request_id);
  // Chromium has completed its sandbox/custom-handler checks and transferred
  // this external application handoff to the host. Native never launches it.
  void (*external_protocol_requested)(
      void* user_data,
      CCSPageRef page,
      CCSExternalProtocolRequestRef request,
      const CCSExternalProtocolRequestV1* state);
  void (*external_protocol_cancelled)(void* user_data,
                                      CCSExternalProtocolRequestRef request,
                                      uint64_t request_id);
  // A DevTools session has lost its frontend or inspected target. The session
  // handle remains valid until CCSDevToolsSessionRelease.
  void (*devtools_session_closed)(void* user_data,
                                  CCSDevToolsSessionRef session);
  void (*client_certificate_requested)(
      void* user_data, CCSPageRef page, CCSClientCertificateRequestRef request,
      const CCSClientCertificateRequestV1* state);
  void (*client_certificate_cancelled)(
      void* user_data, CCSClientCertificateRequestRef request,
      uint64_t request_id);
  void (*extension_install_requested)(
      void* user_data, CCSPageRef page, CCSExtensionInstallRequestRef request,
      const CCSExtensionInstallRequestV1* state);
  void (*extension_install_cancelled)(
      void* user_data, CCSExtensionInstallRequestRef request,
      uint64_t request_id);
  // ABI 17: exact child opening intent, retained across deferred adoption.
  // Preferred over popup_created when supplied.
  void (*popup_created_with_disposition)(void* user_data,
                                         CCSPageRef opener,
                                         CCSPageRef popup,
                                         const char* host_window_id_utf8,
                                         int32_t disposition);
} CCSClientV12;

// Outer-app client entry point. The patched Chromium browser launcher requires
// Contents/Frameworks/CobbleChromiumClient.dylib and calls its
// `CCSClientMain` export with Chromium's already-open framework handle. The
// client resolves CCSSetClient with dlsym(handle, "CCSSetClient") and returns
// zero. It must not create AppKit UI until runtime_ui_ready.
typedef int32_t (*CCSClientMainFn)(void* chromium_framework_handle);
typedef void (*CCSContextOpenedCallback)(void* callback_data,
                                         CCSContextRef context,
                                         const char* error_utf8);
typedef void (*CCSPageDataCallback)(void* callback_data,
                                    const uint8_t* bytes,
                                    size_t length,
                                    const char* error_utf8);

// Register before calling the framework's ChromeMain export. Chromium owns the
// main message loop; every other CCS function and callback runs on that thread.
// The client table is copied. Returns zero on success.
CCS_EXPORT int32_t CCSSetClient(const CCSClientV12* client);
CCS_EXPORT void CCSRequestQuit(uint8_t ignore_unload_handlers);
// Abandons a client-deferred quit after a page refuses to close.
CCS_EXPORT void CCSCancelQuit(void);

// Context handles borrow Chromium Profiles and are valid until runtime stop.
// Release a context only after all pages created from it have closed.
CCS_EXPORT CCSContextRef CCSDefaultContext(void);
// Chromium's supported primary off-the-record profile. Private contexts from
// the same default profile share one in-memory session, matching Chrome.
CCS_EXPORT CCSContextRef CCSPrivateContext(void);
// Opens a normal profile keyed below Chromium's user-data directory. A null or
// empty profile key selects the initial profile. A nonempty private-window key
// creates/reuses a distinct in-memory OTR profile for that window. The callback
// may run synchronously and owns a nonnull context until CCSContextRelease.
// Named private windows intentionally do not support extensions in v1.
CCS_EXPORT void CCSContextOpen(const char* profile_key_utf8,
                    const char* private_window_key_utf8,
                    void* callback_data,
                    CCSContextOpenedCallback callback);
CCS_EXPORT void CCSContextRelease(CCSContextRef context);
// Set before creating pages. Passing a null callback unregisters the resolver.
// Do not navigate or release the context from inside the callback.
CCS_EXPORT void CCSContextSetIdentityResolver(CCSContextRef context,
                                               void* user_data,
                                               CCSIdentityResolver callback);

CCS_EXPORT CCSPageRef CCSPageCreate(CCSContextRef context,
                                   const char* host_window_id_utf8,
                                   const char* initial_url_utf8);
// Returns an unretained NSView*. AppKit may reparent it into a client NSView.
CCS_EXPORT void* CCSPageView(CCSPageRef page);
CCS_EXPORT void CCSPageLoadURL(CCSPageRef page, const char* url_utf8);
CCS_EXPORT void CCSPageGoBack(CCSPageRef page);
CCS_EXPORT void CCSPageGoForward(CCSPageRef page);
// Returns zero when reload is unavailable or would repost form data. Cobble
// never silently turns a POST reload into a GET or asks Chromium to repost.
CCS_EXPORT uint8_t CCSPageReload(CCSPageRef page);
CCS_EXPORT uint8_t CCSPageReloadFromOrigin(CCSPageRef page);
CCS_EXPORT void CCSPageStop(CCSPageRef page);
CCS_EXPORT void CCSPageFocus(CCSPageRef page);
// Propagates host attachment/window visibility into WebContents so Blink page
// visibility, timer throttling and compositor suppression follow Cobble UI.
CCS_EXPORT void CCSPageSetVisible(CCSPageRef page, uint8_t visible);
CCS_EXPORT uint8_t CCSPageMoveToHost(CCSPageRef page,
                                    const char* host_window_id_utf8);
// Find is asynchronous. Returns Chromium's positive request ID, zero when an
// empty query cleared the search, or -1 when unavailable. Match results arrive
// through page_find_result.
CCS_EXPORT int32_t CCSPageFind(CCSPageRef page, const char* text_utf8, uint8_t backwards);
// Returns zero when the page has no zoom controller. Set uses Chromium's zoom
// bounds and isolates the value to this tab; the client supplies its own UI.
CCS_EXPORT double CCSPageGetZoomFactor(CCSPageRef page);
CCS_EXPORT uint8_t CCSPageSetZoomFactor(CCSPageRef page, double factor);
// Uses Chromium's native print command and returns zero when this page is not
// the active printable page in its owning browser.
CCS_EXPORT uint8_t CCSPagePrint(CCSPageRef page);
// Captures the visible page viewport as PNG. Completion runs exactly once;
// byte and error storage are borrowed for the callback only.
CCS_EXPORT void CCSPageCaptureViewportPNG(CCSPageRef page,
                                          void* callback_data,
                                          CCSPageDataCallback callback);
// Returns the current primary document's live, script-mutated outer HTML.
CCS_EXPORT void CCSPageCurrentDOM(CCSPageRef page,
                                  void* callback_data,
                                  CCSPageDataCallback callback);
// Returns Chromium's native MHTML representation of the current primary page.
CCS_EXPORT void CCSPageCreateMHTMLArchive(CCSPageRef page,
                                          void* callback_data,
                                          CCSPageDataCallback callback);
// Returns a versioned JSON snapshot of Chromium's current, URL-matched visible
// security state. Unavailable/uninitialized details are represented in JSON;
// invalid page handles report an error. Bytes are callback-scoped.
CCS_EXPORT void CCSPageCopyConnectionDetailsJSON(
    CCSPageRef page,
    void* callback_data,
    CCSPageDataCallback callback);
// Validates and opens one exact local regular file. Success is reported only
// after its primary document commits. The selected document receives no local
// sibling, directory, subresource, worker, or download access.
CCS_EXPORT void CCSPageOpenLocalFile(CCSPageRef page,
                                     const char* url_utf8,
                                     void* callback_data,
                                     CCSPageDataCallback callback);
// Mutes only this page's local/system audio output. It does not pause media or
// alter microphone, tab, display, or system-audio capture.
CCS_EXPORT uint8_t CCSPageSetAudioMuted(CCSPageRef page, uint8_t muted);
CCS_EXPORT uint8_t CCSPageIsAudioMuted(CCSPageRef page);
// Stops every camera/microphone stream owned by this page. Chromium does not
// provide a safe per-track stop command at this boundary.
CCS_EXPORT uint8_t CCSPageStopMediaCapture(CCSPageRef page);
CCS_EXPORT void CCSPageClose(CCSPageRef page);
// Bypasses beforeunload and immediately destroys a Browser-owned tab. If the
// WebContents has already detached from its Browser, synchronously retires the
// bridge handle without taking ownership of or deleting that WebContents.
CCS_EXPORT void CCSPageForceClose(CCSPageRef page);
CCS_EXPORT uint8_t CCSPageIsClosed(CCSPageRef page);
CCS_EXPORT void CCSPageRelease(CCSPageRef page);

// Opens Chromium's bundled inspector in an undocked client-owned NSWindow.
// The host UUID must already resolve through CCSClientV12.host_window. Only one
// live session is allowed per inspected page. The returned NSView is borrowed
// until devtools_session_closed; docking, secondary inspectors, file-system
// dialogs, certificate UI, and frontend-created tabs are disabled.
CCS_EXPORT CCSDevToolsSessionRef CCSPageOpenDevTools(
    CCSPageRef page,
    const char* host_window_id_utf8);
CCS_EXPORT void* CCSDevToolsSessionView(CCSDevToolsSessionRef session);
CCS_EXPORT void CCSDevToolsSessionFocus(CCSDevToolsSessionRef session);
CCS_EXPORT void CCSDevToolsSessionSetVisible(CCSDevToolsSessionRef session,
                                             uint8_t visible);
// Returns nonzero only for the first accepted close. The close callback may
// run before this function returns and is delivered exactly once.
CCS_EXPORT uint8_t CCSDevToolsSessionClose(CCSDevToolsSessionRef session);
CCS_EXPORT uint8_t CCSDevToolsSessionIsClosed(CCSDevToolsSessionRef session);
CCS_EXPORT void CCSDevToolsSessionRelease(CCSDevToolsSessionRef session);

// Resolves a pending camera/microphone request exactly once. Returns zero for
// an unknown, already-resolved, or stale request. Allowed requests still pass
// Chromium device availability, document/origin, Permissions Policy and macOS
// system-permission checks.
CCS_EXPORT uint8_t CCSMediaPermissionResolve(
    CCSMediaPermissionRequestRef request,
    uint8_t allow);
CCS_EXPORT uint8_t CCSJavaScriptDialogResolve(
    CCSJavaScriptDialogRequestRef request,
    uint8_t accept,
    const char* prompt_utf8);
CCS_EXPORT uint8_t CCSHTTPAuthResolve(CCSHTTPAuthRequestRef request,
                                      const char* username_utf8,
                                      const char* password_utf8);
CCS_EXPORT uint8_t CCSHTTPAuthCancel(CCSHTTPAuthRequestRef request);
CCS_EXPORT uint8_t CCSFileChooserResolve(CCSFileChooserRequestRef request,
                                         const char* const* paths_utf8,
                                         size_t path_count);
// Retires a pending external application handoff. Both decisions are terminal;
// native never opens the URL. After a successful allow, the host may open it.
CCS_EXPORT uint8_t CCSExternalProtocolResolve(
    CCSExternalProtocolRequestRef request,
    uint8_t allow);
CCS_EXPORT uint8_t CCSClientCertificateSelect(
    CCSClientCertificateRequestRef request, uint64_t choice_id);
CCS_EXPORT uint8_t CCSClientCertificateCancel(
    CCSClientCertificateRequestRef request);
CCS_EXPORT uint8_t CCSExtensionInstallResolve(
    CCSExtensionInstallRequestRef request, uint8_t accept);

// Resolves Chromium's pending target determination exactly once. A null or
// empty path cancels. The client supplies a nonexistent staging file whose
// basename retains the user-selected extension; Chromium owns all writes and
// quarantine annotation until a terminal state callback.
CCS_EXPORT void CCSDownloadSetDestination(CCSDownloadRef download,
                               const char* staging_path_utf8);
typedef void (*CCSDownloadCancelCallback)(void* callback_data);
// Completion runs on Chromium's UI thread after its sequenced download-file
// work has closed the staging file. The callback data is borrowed until then.
CCS_EXPORT void CCSDownloadCancel(CCSDownloadRef download,
                       void* callback_data,
                       CCSDownloadCancelCallback callback);
// Bits: 1 can pause, 2 can resume, 4 is paused. Zero is invalid, terminal, or
// unsafe to control.
CCS_EXPORT uint32_t CCSDownloadGetControlState(CCSDownloadRef download);
CCS_EXPORT uint8_t CCSDownloadSetPaused(CCSDownloadRef download,
                                        uint8_t paused);
CCS_EXPORT void CCSDownloadRelease(CCSDownloadRef download);

#if defined(__cplusplus)
}  // extern "C"

#include <memory>
#include <string>
#include "content/public/browser/media_stream_request.h"

namespace base {
class FilePath;
}

class Browser;
class BrowserWindow;
class ChromeBrowserMainExtraParts;
class Profile;
class GURL;

namespace url {
class Origin;
}

namespace content {
class RenderFrameHost;
class WebContents;
}

namespace cobble_chromium {

bool IsEnabled();
bool IsStopping();
bool HandleMediaAccessRequest(content::WebContents* contents,
                              const content::MediaStreamRequest& request,
                              content::MediaResponseCallback callback);
bool ShouldAllowPopup(content::RenderFrameHost* opener,
                      const GURL& opener_url,
                      const GURL& top_level_url,
                      const url::Origin& source_origin,
                      const GURL& target_url,
                      int disposition,
                      bool user_gesture,
                      bool opener_suppressed);
const CCSClientV12& Client();
std::string& PendingHostWindowIDForDevTools();
uint64_t NextPromptRequestID();
void RegisterShutdownCallback(void (*callback)());
std::unique_ptr<ChromeBrowserMainExtraParts> CreateMainExtraParts();
void RegisterBrowser(Browser* browser, BrowserWindow* window);
void UnregisterBrowser(Browser* browser);
CCSPageRef PageForWebContents(content::WebContents* contents);
content::WebContents* PageWebContents(CCSPageRef page);
bool PageAcceptsPromptResult(CCSPageRef page,
                             content::WebContents* contents);
bool PageHasPendingPromptOrMedia(CCSPageRef page);
void CancelPageCaptures(content::WebContents* contents);
void* HostWindowForWebContents(content::WebContents* contents);
void* HostWindowForBrowser(Browser* browser);
void BrowserActiveTabChanged(content::WebContents* old_contents,
                             content::WebContents* new_contents);
void BrowserPageStateChanged(content::WebContents* contents);
void BrowserTargetURLChanged(content::WebContents* contents, const GURL& url);
void BrowserTabStripChanged(Browser* browser);
Profile* ContextProfile(CCSContextRef context);
bool ResolveProfileKey(const char* key,
                       base::FilePath* path,
                       Profile** loaded_profile,
                       std::string* error);
bool HasPendingProfileOpen(const base::FilePath& path);
bool HasProfileBridgeWork(const base::FilePath& path, Profile* loaded_profile);
bool HasContextLease(Profile* profile);
bool RetainPrivateProfileLease(Profile* profile);
void ReleasePrivateProfileLease(Profile* profile);
bool DeferAppQuit(bool system_shutdown);
bool HandleAppReopen();
bool HandleAppOpenURLs(void* urls);
bool NotifyDownloadCreated(CCSPageRef page,
                           CCSDownloadRef download,
                           const char* suggested_filename);
void NotifyDownloadStateChanged(CCSDownloadRef download,
                                const CCSDownloadStateV1* state);

}  // namespace cobble_chromium
#endif

#endif  // CHROME_BROWSER_UI_COBBLE_COBBLE_CHROMIUM_H_
