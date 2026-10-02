"""Exercise the public ABI under Chromium's hidden-visibility compiler setting."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).parents[1]


@unittest.skipUnless(sys.platform == "darwin", "Requires the macOS linker")
class ABIExportTests(unittest.TestCase):
    def test_sdk_suppresses_only_unused_launch_networking(self):
        patch = (ROOT / "chromium/patches/0023-suppress-unused-background-networking.patch").read_text()

        for boundary in (
            "updater_options.append(\"disable-pings\")",
            "syncer::kDisableSync",
            "GetSwitchValueASCII(\n+            switches::kComponentUpdater)",
            "updater_options.push_back(',')",
            "if (cobble_chromium::IsEnabled())",
            "return nullptr",
            "if (!intranet_redirect_detector_)",
            "config.disabled = cobble_chromium::IsEnabled()",
            "if (configuration_.disabled ||",
            "AccountInvestigatorFactory::ServiceIsCreatedWithBrowserContext",
            "This service only reports Chrome account-cookie metrics",
        ):
            self.assertIn(boundary, patch)

        self.assertEqual(patch.count("if (configuration_.disabled ||"), 2)
        self.assertEqual(patch.count("if (configuration_.disabled)"), 3)
        self.assertIn("bool disabled = false", patch)
        investigator = patch[patch.index("chrome/browser/signin/account_investigator_factory.cc"):].split("\ndiff --git ", 1)[0]
        self.assertEqual(2, investigator.count("cobble_chromium::IsEnabled()"))
        self.assertIn("BuildServiceInstanceForBrowserContext", investigator)
        self.assertIn("return nullptr", investigator)
        self.assertIn("ServiceIsCreatedWithBrowserContext", investigator)
        self.assertIn("return false", investigator)
        self.assertIn("return true", investigator)
        session_metrics = patch[patch.index("chrome/browser/metrics/desktop_session_duration/desktop_profile_session_durations_service_factory.cc"):]
        self.assertIn("if (cobble_chromium::IsEnabled())", session_metrics)
        self.assertIn("return nullptr", session_metrics)
        self.assertIn("Google account cookie jar at startup", session_metrics)

        profile_manager = patch[patch.index("chrome/browser/profiles/profile_manager.cc"):].split("\ndiff --git ", 1)[0]
        self.assertIn("IdentityManagerFactory::GetForProfile(profile)->OnNetworkInitialized()", profile_manager)
        self.assertIn("if (!cobble_chromium::IsEnabled())", profile_manager)
        self.assertEqual(2, profile_manager.count("AccountReconcilorFactory::GetForProfile(profile)"))
        self.assertIn("Explicit\n+  // sign-in consumers still instantiate", profile_manager)

        # Security update fetching remains enabled. This patch suppresses
        # component result pings without disabling component or background
        # networking globally.
        self.assertNotIn("kDisableComponentUpdate", patch)
        self.assertNotIn("kDisableBackgroundNetworking", patch)

    def test_unmanaged_cobble_profiles_do_not_start_policy_gcm(self):
        patch = (ROOT / "chromium/patches/0024-suppress-unmanaged-policy-gcm.patch").read_text()
        self.assertEqual(2, patch.count("cobble_chromium::IsEnabled()"))
        self.assertEqual(4, patch.count("#if BUILDFLAG(IS_MAC)"))
        self.assertEqual(2, patch.count("!store->is_initialized() || !store->is_managed()"))
        self.assertNotIn("IsClientRegistered()", patch)
        for source in ("user_cloud_policy_invalidator.cc",
                       "user_fm_registration_token_uploader.cc"):
            section = patch[patch.index("a/chrome/browser/policy/cloud/" + source):]
            section = section.split("\ndiff --git ", 1)[0]
            self.assertIn("store_observation_.Observe(policy_manager_->core()->store())", section)
            self.assertIn("OnStoreLoaded(CloudPolicyStore* store)", section)
            self.assertIn("OnStoreError(CloudPolicyStore* store) {}", section)
            self.assertIn("store_observation_.Reset()", section)
        for untouched in ("gcm_profile_service_factory.cc",
                          "instance_id_profile_service_factory.cc",
                          "profile_invalidation_provider_factory.cc",
                          "user_cloud_policy_invalidator_factory.cc",
                          "user_fm_registration_token_uploader_factory.cc"):
            self.assertNotIn(untouched, patch)

    def test_post_reload_is_deferred_for_owned_confirmation(self):
        header = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.h").read_text()
        self.assertIn("#define CCS_ABI_VERSION 18u", header)
        self.assertIn("CCS_JAVASCRIPT_DIALOG_FORM_REPOST = 4", header)

        prompts = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_prompts.mm").read_text()
        for boundary in ("PageHasPendingPromptOrMedia(page)",
                         "CCS_JAVASCRIPT_DIALOG_FORM_REPOST",
                         "FinishJavaScript(request_id, false, {}, true)"):
            self.assertIn(boundary, prompts)

        patch = (ROOT / "chromium/patches/0015-deny-unowned-browser-ui.patch").read_text()
        throttle = patch[patch.index("class CobblePostReloadNavigationThrottle"):
                         patch.index("void ChromeContentBrowserClient::CreateThrottlesForNavigation")]
        for boundary in ("return DEFER", "RequestFormRepostConfirmation",
                         "Resume()", "CancelDeferredNavigation(CANCEL_AND_IGNORE)",
                         "CancelFormRepostConfirmation(prompt_id_)"):
            self.assertIn(boundary, throttle)
        self.assertNotIn("return CANCEL_AND_IGNORE;", throttle)
        show_repost = patch[patch.index("ShowRepostFormWarningDialog"):
                            patch.index("TabModalConfirmDialog::Create")]
        for boundary in ("GetUniqueID()", "GetWeakDocumentPtr()",
                         "AsRenderFrameHostIfValid()",
                         "GetPendingEntry()", "PageHasPendingPromptOrMedia(page)",
                         "CancelPendingReload()"):
            self.assertIn(boundary, show_repost)

        for source, function in (("cobble_chromium.mm", 'extern "C" uint8_t CCSPageReload('),
                                 ("cobble_page_operations.mm", "uint8_t CCSPageReloadFromOrigin(")):
            text = (ROOT / "chromium/overlay/chrome/browser/ui/cobble" / source).read_text()
            body = text[text.index(function):text.index("\n}", text.index(function))]
            self.assertIn("/*check_for_repost=*/true", body)
            self.assertNotIn("GetHasPostData", body)

        page_observer = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.mm").read_text()
        for callback in ("LocalFileNavigationStarted(this, handle)",
                         "LocalFileNavigationFinished(this, handle)",
                         "LocalFileRenderProcessGone(this)"):
            following = page_observer[page_observer.index(callback):][:240]
            self.assertIn("closed || !web_contents()", following)

    def test_local_file_reload_uses_owned_async_operation(self):
        local_file = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_local_file.mm").read_text()
        self.assertIn("replace_current_entry |= active_url_ == requested",
                      local_file)
        self.assertIn("bool IsLocalFileActive(CCSPageRef page)", local_file)
        for pdf_boundary in ('FILE_PATH_LITERAL(".pdf")', '== "%PDF-"'):
            self.assertIn(pdf_boundary, local_file)

        page = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.mm").read_text()
        reload_body = page[page.index('extern "C" uint8_t CCSPageReload('):
                           page.index('extern "C" uint8_t CCSMediaPermissionResolve(')]
        self.assertIn("IsLocalFileActive(page)", reload_body)
        self.assertIn("routes this through async openLocalFile", reload_body)

    def test_native_download_retry_policy_is_opt_in_and_pre_request(self):
        patch = (ROOT / "chromium/patches/0019-block-unsafe-native-download-retry.patch").read_text()

        # The base method is deliberately inert, so ordinary Chromium callers
        # retain upstream behavior until the Cobble delegate opts an item out.
        self.assertIn("+void DownloadItem::DisallowResumption() {}", patch)
        attach = patch[patch.index("void ChromeDownloadManagerDelegate::AttachExtraInfo("):]
        for boundary in ("cobble_chromium::IsEnabled()",
                         "!item->WasCreatedFromGET()",
                         "!item->GetOriginalUrl().SchemeIsHTTPOrHTTPS()",
                         "!item->GetURL().SchemeIsHTTPOrHTTPS()",
                         "item->DisallowResumption()"):
            self.assertIn(boundary, attach)

        # GetResumeMode prevents automatic retry. The method-entry guard also
        # runs before any request setup, including the later service-worker
        # restart override in ResumeInterruptedDownload.
        self.assertIn("+  if (resumption_disallowed_) {\n"
                      "+    return ResumeMode::INVALID;", patch)
        resume_start = patch.index("ResumptionRequestSource source) {")
        resume_entry = patch[
            resume_start:patch.index(
                "diff --git a/chrome/browser/download/", resume_start)]
        self.assertIn("state_ != INTERRUPTED_INTERNAL || resumption_disallowed_",
                      resume_entry)
        self.assertLess(resume_entry.index("resumption_disallowed_"),
                        resume_entry.index("Shake off all pending operations"))

    def test_owned_devtools_stays_undocked_and_fails_closed(self):
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_devtools.mm").read_text()
        open_body = source[source.index('extern "C" CCSDevToolsSessionRef CCSPageOpenDevTools'):
                           source.index('extern "C" void* CCSDevToolsSessionView')]
        for boundary in ("SessionForPage(page)", "PageHasPendingPromptOrMedia(page)",
                         "Client().host_window", "PageForWebContents(inspected) != page"):
            self.assertIn(boundary, open_body)
        patch = (ROOT / "chromium/patches/0016-own-devtools-window.patch").read_text()
        for method in ("OpenURLFromTab", "RunFileChooser", "Inspect(", "SetIsDocked", "OpenInNewTab",
                       "ShowCertificateViewer", "SetOpenNewWindowForPopups"):
            start = patch.index(method)
            self.assertIn("IsOwnedDevTools", patch[start:start + 900])

    def test_external_protocol_source_keeps_nonlaunchable_boundaries(self):
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_prompts.mm").read_text()
        body = source[source.index("void HandleExternalProtocol("):
                      source.index("bool PageHasPendingPrompt(")]
        for scheme in ("http", "https", "file", "about", "data", "javascript",
                       "blob", "filesystem", "chrome", "chrome-extension", "devtools"):
            self.assertIn(f'scheme == "{scheme}"', body)
        for boundary in ("!user_gesture", "!primary_main_frame", "fenced_frame"):
            self.assertIn(boundary, body)

    def test_sdk_runtime_denies_unowned_picture_in_picture_windows(self):
        patch = (ROOT / "chromium/patches/0015-deny-unowned-browser-ui.patch").read_text()
        document_gate = patch[patch.rindex("IsDocumentPictureInPictureBlockedBySystem"):]
        self.assertIn("cobble_chromium::IsEnabled()", document_gate[:500])
        video = patch[patch.index("BrowserWebContentsDelegate::EnterPictureInPicture"):]
        self.assertIn("cobble_chromium::IsEnabled()", video[:600])
        self.assertIn("PictureInPictureResult::kNotSupported", video[:600])
        document = patch[patch.index("chrome/browser/ui/navigator/browser_navigator.cc"):]
        pip = document[document.index("WindowOpenDisposition::NEW_PICTURE_IN_PICTURE"):]
        self.assertIn("cobble_chromium::IsEnabled()", pip[:500])
        self.assertIn("return nullptr", pip[:500])

    def test_extension_completion_waits_for_dnr_matcher_readiness(self):
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_extensions.mm").read_text()
        for boundary in ("WaitForInitialRulesets", "PendingRulesReadiness",
                         "ScopedClosureRunner", "HasAnyDNRPermission"):
            self.assertIn(boundary, source)
        self.assertEqual(3, source.count("ReplyWhenRulesReady("))
        patch = (ROOT / "chromium/patches/0022-wait-for-dnr-readiness.patch").read_text()
        for boundary in ("ExecuteOrQueueApiCall", "initial_ruleset_load_failures_",
                         "failed to load"):
            self.assertIn(boundary, patch)

    def test_website_data_removal_has_bounded_categories_scope_and_time(self):
        header = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_website_data.h").read_text()
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_website_data.mm").read_text()
        swift = (ROOT / "Sources/CobbleChromium/ChromiumWebsiteData.swift").read_text()
        for boundary in ("CCS_WEBSITE_DATA_SITE_DATA", "CCS_WEBSITE_DATA_CACHE",
                         "CCSWebsiteDataRemovalV1", "modified_since_unix_seconds",
                         "CCSWebsiteDataRemove"):
            self.assertIn(boundary, header)
        remove = source[source.index('extern "C" void CCSWebsiteDataRemove('):
                        source.index('extern "C" void CCSWebsiteDataClearCache(')]
        for boundary in ("kKnownCategories", "all_time > 1", "strnlen(",
                         "IsCanonicalRegistrableDomain", "std::isfinite",
                         "CCS_WEBSITE_DATA_SITE_DATA", "base::Time::Now()"):
            self.assertIn(boundary, remove)
        self.assertIn("ORIGIN_TYPE_UNPROTECTED_WEB", source)
        self.assertIn("RemoveWithFilterAndReply", source)
        self.assertIn("RemoveAndReply", source)
        self.assertIn("ChromiumWebsiteDataCategories", swift)
        self.assertIn("modifiedSince: Date? = nil", swift)
        self.assertIn("Pure HTTP-cache entries may not appear", swift.replace("\n    ///", ""))
        legacy = source[source.index('extern "C" void CCSWebsiteDataRemoveSite('):]
        self.assertIn('registrable_domain_utf8 ? registrable_domain_utf8 : ""',
                      legacy)
        self.assertIn("CCSWebsiteDataRemovalV1 removal", legacy)
        self.assertIn("CCSWebsiteDataRemove(context, &removal", legacy)
        self.assertNotIn("const std::string domain", legacy)

    def test_cookie_transfer_is_host_scoped_and_fail_closed(self):
        header = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_website_data.h").read_text()
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_website_data.mm").read_text()
        swift = (ROOT / "Sources/CobbleChromium/ChromiumWebsiteData.swift").read_text()
        for boundary in ("CCSCookiesExport", "CCSCookiesReplace"):
            self.assertIn(boundary, header)
            self.assertIn(boundary, source)
        for boundary in ("cookie.IsDomainMatch(host_)", "cookie.IsPartitioned()",
                         "CookieSourceScheme::kSecure", "cookie.SourcePort() == 443",
                         "Existing cookies contain unsupported metadata",
                         "ParseCookies(cookies_json_utf8", "DeleteNext()", "SetNext()"):
            self.assertIn(boundary, source)
        for boundary in ("domain_cookie ? *domain : \"\"", "cookie->Domain() != *domain",
                         "cookie->ExpiryDate() != expiry", "expiry <= now",
                         "WrapCallbackWithDropHandler",
                         "WrapCallbackWithDefaultInvokeIfNotRun"):
            self.assertIn(boundary, source)
        self.assertLess(source.index("auto cookies = ParseCookies(cookies_json_utf8"),
                        source.index("request_pointer->Replace(std::move(*cookies))"))
        replacement = source[source.index("class PendingCookies final"):]
        self.assertIn("if (rejected_)", replacement)
        set_call = replacement[replacement.index("manager_->SetCanonicalCookie("):
                               replacement.index("void Set(net::CookieAccessResult")]
        self.assertIn("WrapCallbackWithDropHandler", set_call)
        self.assertNotIn("net::CookieAccessResult()", set_call)
        self.assertLess(replacement.index("SetNext();"), replacement.index("void DeleteNext()"))
        self.assertIn('snapshot.Set("skipped"', source)
        for boundary in ("public struct ChromiumCookie", "public init(name:",
                         "ChromiumCookieSnapshot", "func cookies(forHTTPSHost",
                         "replaceCookies(_ cookies:"):
            self.assertIn(boundary, swift)
        self.assertIn("encodeNil(forKey: .expiry)", swift)

    def test_client_certificate_bridge_preserves_exact_context_and_native_keys(self):
        source = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_client_certificates.mm").read_text()
        core = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.mm").read_text()
        runtime = (ROOT / "Sources/CobbleChromium/ChromiumRuntime.swift").read_text()
        for boundary in ("NavigationOrDocumentHandle", "GetNavigationId()",
                         "GetGlobalFrameToken()", "SelfOwningAcquirePrivateKey",
                         "PageHasPendingPromptOrMedia", "choices_truncated",
                         "kMaxOriginBytes", "CanonicalSerial"):
            self.assertIn(boundary, source)
        self.assertNotIn("ContinueWithCertificate(nullptr", source)
        patch = (ROOT / "chromium/patches/0021-own-client-certificates.patch").read_text()
        self.assertIn("SelectClientCertificateWithContext", patch)
        selection = patch[patch.index("ChromeContentBrowserClient::SelectClientCertificateWithContext"):]
        self.assertLess(selection.index("!CanPromptWithNonmatchingCertificates"),
                        selection.index("HandleClientCertificateRequest"))
        for boundary in ("cobble-client-cert-test-keychain",
                         "kSecMatchSearchList", "SecKeychainOpen",
                         "S_ISREG", "restricted_keychain_path.empty()"):
            self.assertIn(boundary, patch + source)
        self.assertIn("if (!restricted_keychain && !server_domain.empty())", patch)
        self.assertIn("restricted_keychain_path.empty(),", patch)
        self.assertNotIn("SecTrustSetKeychains", patch)
        for boundary in ("!State().stopping", "FindPage(contents) == page",
                         "!page->released", "!page->close_requested"):
            self.assertIn(boundary, core)
        self.assertGreaterEqual(core.count("PageAcceptsPromptResult("), 2)
        media_finish = core[core.index("void FinishMediaRequest("):
                            core.index("void ContinueAllowedMediaRequest(")]
        self.assertIn("result == MediaResult::OK && !MediaRequestIsLive", media_finish)
        callback = runtime[runtime.index("client.client_certificate_requested ="):
                           runtime.index("client.client_certificate_cancelled =")]
        self.assertIn("guard let data, let requestHandle else", callback)
        self.assertIn("client_certificate_cancel?(requestHandle)", callback)
        self.assertIn("current->id != request_id", source)
        self.assertIn("serial.size() > 1 && serial.front() == 0", source)
        self.assertIn("serial = serial.subspan(size_t{1})", source)
        self.assertIn("Bound(CanonicalSerial(cert->serial_number()))", source)

    def test_prompt_results_revalidate_after_host_state_callbacks(self):
        core = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_chromium.mm").read_text()
        prompts = (ROOT / "chromium/overlay/chrome/browser/ui/cobble/cobble_prompts.mm").read_text()
        media = core[core.index("void FinishMediaRequest("):
                     core.index("void ContinueAllowedMediaRequest(")]
        self.assertLess(media.index("request->page->SendState()"),
                        media.index("!MediaRequestIsLive(*request)"))
        javascript = prompts[prompts.index("void FinishJavaScript("):
                             prompts.index("CCSFileChooserRequest* FindFile") ]
        self.assertLess(javascript.index("StateChanged(contents)"),
                        javascript.index("const bool frame_is_live"))
        self.assertIn("accept = false", javascript)
        self.assertIn("CCS_JAVASCRIPT_DIALOG_BEFORE_UNLOAD", javascript)
        self.assertIn("PageAcceptsPromptResult(page, contents)", javascript)
        auth = prompts[prompts.index('extern "C" uint8_t CCSHTTPAuthResolve'):
                       prompts.index('extern "C" uint8_t CCSHTTPAuthCancel')]
        self.assertLess(auth.index("StateChanged(contents)"),
                        auth.index("PageAcceptsPromptResult(page, contents)"))
        self.assertIn("Run(std::nullopt)", auth)

    def test_framework_export_patches_include_every_loader_export(self):
        required = set(re.findall(r'RESOLVE\(\w+, "(CCS\w+)"\)',
                                 (ROOT / "Sources/CCobbleChromium/CCSLoader.c").read_text()))
        exported = set()
        for path in sorted((ROOT / "chromium/patches").glob("*.patch")):
            patch = path.read_text()
            match = re.search(
                r"^diff --git a/chrome/app/framework\.exports "
                r"b/chrome/app/framework\.exports\n(.*?)(?=^diff --git |\Z)",
                patch, re.MULTILINE | re.DOTALL)
            if match:
                for operation, symbol in re.findall(
                        r"^([+-])_(CCS\w+)$", match.group(1), re.MULTILINE):
                    (exported.add if operation == "+" else exported.discard)(symbol)
        self.assertEqual(exported, required)

    def test_framework_order_patch_includes_every_loader_export(self):
        required = set(re.findall(r'RESOLVE\(\w+, "(CCS\w+)"\)',
                                 (ROOT / "Sources/CCobbleChromium/CCSLoader.c").read_text()))
        patch = (ROOT / "chromium/patches/0011-order-sdk-exports.patch").read_text()
        added = re.findall(r"^\+_(CCS\w+)$", patch, re.MULTILINE)
        self.assertEqual(set(added), required)
        self.assertEqual(len(added), len(required))
        self.assertLess(patch.rfind("+_CCS"), patch.rfind(" _ChromeMain"))

    def test_loader_functions_remain_exported_with_hidden_visibility(self):
        headers = ROOT / "chromium/overlay/chrome/browser/ui/cobble"
        names = ["cobble_chromium.h", "cobble_extensions.h", "cobble_website_data.h",
                 "cobble_profile_deletion.h"]
        declarations = re.findall(
            r"(uint32_t|int32_t|uint8_t|double|void\*?|CCSContextRef|CCSPageRef|CCSDevToolsSessionRef) "
            r"(CCS\w+)\(([^;]*?)\);",
            "\n".join((headers / name).read_text() for name in names))
        required = set(re.findall(r'RESOLVE\(\w+, "(CCS\w+)"\)',
                                 (ROOT / "Sources/CCobbleChromium/CCSLoader.c").read_text()))
        self.assertTrue(required)
        self.assertEqual({name for _, name, _ in declarations}, required)
        # Stub bodies test linkage only. They never stand in for runtime tests.
        source = "\n".join(f'#include "{name}"' for name in names) + "\n"
        source += "\n".join(f"{kind} {name}({arguments}) {{"
                            + ("" if kind == "void" else "return 0;") + "}"
                            for kind, name, arguments in declarations)
        with tempfile.TemporaryDirectory(prefix="ocs-abi-exports-") as directory:
            directory = Path(directory)
            implementation = directory / "exports.c"
            implementation.write_text(source)
            exports = directory / "exports.list"
            exports.write_text("\n".join("_" + name for name in sorted(required)) + "\n")
            binary = directory / "libexports.dylib"
            subprocess.run(["xcrun", "clang", "-dynamiclib", "-fvisibility=hidden",
                            "-I", str(headers), str(implementation),
                            "-Wl,-exported_symbols_list," + str(exports),
                            "-o", str(binary)], check=True, capture_output=True)
            symbols = subprocess.check_output(["nm", "-gU", str(binary)], text=True)
            actual = {line.split()[-1].removeprefix("_") for line in symbols.splitlines() if line.split()}
            self.assertEqual(actual, required)


if __name__ == "__main__":
    unittest.main()
