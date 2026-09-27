// Copyright 2026 Cobble Chromium SDK Authors
// SPDX-License-Identifier: GPL-3.0-only

#include "chrome/browser/ui/cobble/cobble_browser_window.h"

#import <Cocoa/Cocoa.h>

#include <algorithm>
#include <utility>

#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/autofill_bubble_handler.h"
#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "chrome/browser/ui/browser.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/cobble/cobble_chromium.h"
#include "chrome/browser/ui/global_error/global_error.h"
#include "chrome/browser/ui/global_error/global_error_service.h"
#include "chrome/browser/ui/global_error/global_error_service_factory.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/startup_metric_utils/browser/startup_metric_utils.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/range/range.h"
#include "ui/native_theme/native_theme.h"

namespace {

NSWindow* HostWindow(Browser* browser) {
  return (__bridge NSWindow*)cobble_chromium::HostWindowForBrowser(browser);
}

gfx::Rect BoundsForWindow(NSWindow* window) {
  if (!window) {
    return gfx::Rect(0, 0, 1280, 800);
  }
  const NSRect frame = window.frame;
  NSScreen* screen = window.screen ?: NSScreen.screens.firstObject;
  const CGFloat y = screen ? NSMaxY(screen.frame) - NSMaxY(frame) : NSMinY(frame);
  return gfx::Rect(NSMinX(frame), y, NSWidth(frame), NSHeight(frame));
}

class CobbleAutofillBubbleHandler final
    : public autofill::AutofillBubbleHandler {
 public:
  autofill::AutofillBubbleBase* ShowSaveCreditCardBubble(
      content::WebContents*, autofill::SaveCardBubbleController*, bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowIbanBubble(
      content::WebContents*, autofill::IbanBubbleController*, bool,
      autofill::IbanBubbleType) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowOfferNotificationBubble(
      content::WebContents*, autofill::OfferNotificationBubbleController*,
      bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowSaveAutofillAiDataBubble(
      content::WebContents*,
      autofill::AutofillAiImportDataController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowAutofillAiLocalSaveNotification(
      content::WebContents*,
      autofill::AutofillAiImportDataController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowSaveAddressProfileBubble(
      content::WebContents*,
      std::unique_ptr<autofill::SaveAddressBubbleController>, bool) override {
    return nullptr;
  }
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
  autofill::AutofillBubbleBase* ShowAddressSignInPromo(
      content::WebContents*, const autofill::AutofillProfile&) override {
    return nullptr;
  }
#endif
  autofill::AutofillBubbleBase* ShowUpdateAddressProfileBubble(
      content::WebContents*,
      std::unique_ptr<autofill::UpdateAddressBubbleController>, bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowFilledCardInformationBubble(
      content::WebContents*,
      autofill::FilledCardInformationBubbleController*, bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowVirtualCardEnrollBubble(
      content::WebContents*, autofill::VirtualCardEnrollBubbleController*,
      bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowVirtualCardEnrollConfirmationBubble(
      content::WebContents*,
      autofill::VirtualCardEnrollBubbleController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowMandatoryReauthBubble(
      content::WebContents*, autofill::MandatoryReauthBubbleController*, bool,
      autofill::MandatoryReauthBubbleType) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowSaveCardConfirmationBubble(
      content::WebContents*, autofill::SaveCardBubbleController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowSaveIbanConfirmationBubble(
      content::WebContents*, autofill::IbanBubbleController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowOmniboxAutofillBubble(
      content::WebContents*,
      autofill::OmniboxAutofillBubbleController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowPaymentsChurnedUsersBubble(
      content::WebContents*,
      autofill::PaymentsChurnedUsersBubbleController*, bool) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowPaymentsChurnedUsersConfirmationBubble(
      content::WebContents*,
      autofill::PaymentsChurnedUsersBubbleController*) override {
    return nullptr;
  }
  autofill::AutofillBubbleBase* ShowWalletReminderNoticeBubble(
      content::WebContents*, autofill::WalletReminderNoticeBubbleController*,
      bool) override {
    return nullptr;
  }
};

}  // namespace

FindBarController* CobbleFindBar::GetFindBarController() const {
  return controller_;
}
void CobbleFindBar::SetFindBarController(FindBarController* controller) {
  controller_ = controller;
}
void CobbleFindBar::Show(bool, bool) {}
void CobbleFindBar::Hide(bool) {}
void CobbleFindBar::SetFocusAndSelection() {}
void CobbleFindBar::ClearResults(const find_in_page::FindNotificationDetails&) {}
void CobbleFindBar::StopAnimation() {}
void CobbleFindBar::MoveWindowIfNecessary() {}
void CobbleFindBar::SetFindTextAndSelectedRange(const std::u16string&,
                                               const gfx::Range&) {}
std::u16string_view CobbleFindBar::GetFindText() const { return {}; }
gfx::Range CobbleFindBar::GetSelectedRange() const { return {}; }
void CobbleFindBar::UpdateUIForFindResult(
    const find_in_page::FindNotificationDetails&, const std::u16string&) {}
void CobbleFindBar::AudibleAlert() { NSBeep(); }
bool CobbleFindBar::IsFindBarVisible() const { return false; }
void CobbleFindBar::RestoreSavedFocus() {}
bool CobbleFindBar::HasGlobalFindPasteboard() const { return false; }
void CobbleFindBar::UpdateFindBarForChangedWebContents() {}
bool CobbleFindBar::CanPopulateFromSelectedText() { return false; }
const FindBarTesting* CobbleFindBar::GetFindBarTesting() const { return nullptr; }
bool CobbleFindBar::HasFocus() const { return false; }
void CobbleFindBar::CloseOverlappingBubbles() {}
views::Widget* CobbleFindBar::GetHostWidget() { return nullptr; }

CobbleLocationBar::CobbleLocationBar(Browser* browser)
    : LocationBar(nullptr), browser_(browser) {}
void CobbleLocationBar::FocusLocation(bool, bool) {}
void CobbleLocationBar::FocusSearch() {}
void CobbleLocationBar::UpdateFocusBehavior(bool) {}
void CobbleLocationBar::UpdateContentSettingsIcons() {}
void CobbleLocationBar::SaveStateToContents(content::WebContents*) {}
void CobbleLocationBar::Revert() {}
OmniboxView* CobbleLocationBar::GetOmniboxView() { return nullptr; }
OmniboxPopupView* CobbleLocationBar::GetOmniboxPopupView() { return nullptr; }
OmniboxController* CobbleLocationBar::GetOmniboxController() { return nullptr; }
bool CobbleLocationBar::ShouldCloseOmniboxPopup(ui::MouseEvent*) { return false; }
content::WebContents* CobbleLocationBar::GetWebContents() {
  return browser_->tab_strip_model()->GetActiveWebContents();
}
LocationBarModel* CobbleLocationBar::GetLocationBarModel() { return nullptr; }
std::optional<bubble_anchor_util::AnchorConfiguration>
CobbleLocationBar::GetChipAnchor() { return std::nullopt; }
ChipController* CobbleLocationBar::GetChipController() { return nullptr; }
void CobbleLocationBar::AnnounceAlert(const std::u16string& announcement) {
  NSWindow* window = HostWindow(browser_);
  if (!window.isKeyWindow || announcement.empty())
    return;
  NSAccessibilityPostNotificationWithUserInfo(
      NSApp, NSAccessibilityAnnouncementRequestedNotification,
      @{NSAccessibilityAnnouncementKey: base::SysUTF16ToNSString(announcement),
        NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
}
void CobbleLocationBar::OnChanged() {}
void CobbleLocationBar::UpdateWithoutTabRestore() {}
ui::TrackedElement* CobbleLocationBar::GetAnchorOrNull() { return nullptr; }
BrowserWindowInterface* CobbleLocationBar::GetBrowser() { return browser_; }
Profile* CobbleLocationBar::GetProfile() { return browser_->GetProfile(); }
bool CobbleLocationBar::IsInitialized() const { return true; }
bool CobbleLocationBar::IsVisible() const { return false; }
bool CobbleLocationBar::IsDrawn() const { return false; }
bool CobbleLocationBar::IsFullscreen() const {
  NSWindow* window = HostWindow(browser_);
  return window && (window.styleMask & NSWindowStyleMaskFullScreen);
}
bool CobbleLocationBar::IsEditingOrEmpty() const { return false; }
bool CobbleLocationBar::IsMouseHovered() const { return false; }
bool CobbleLocationBar::IsFocusWithin() const { return false; }
void CobbleLocationBar::InvalidateLayout() {}
gfx::Rect CobbleLocationBar::Bounds() const { return {}; }
gfx::Rect CobbleLocationBar::BoundsInScreen() const { return {}; }
gfx::Size CobbleLocationBar::MinimumSize() const { return {}; }
gfx::Size CobbleLocationBar::PreferredSize() const { return {}; }
void CobbleLocationBar::Update(content::WebContents*) {}
void CobbleLocationBar::ResetTabState(content::WebContents*) {}
bool CobbleLocationBar::HasSecurityStateChanged() { return false; }
LocationBarTesting* CobbleLocationBar::GetLocationBarForTesting() {
  return nullptr;
}

CobbleExclusiveAccessContext::CobbleExclusiveAccessContext(Browser* browser)
    : browser_(browser) {}
Profile* CobbleExclusiveAccessContext::GetProfile() {
  return browser_->GetProfile();
}
bool CobbleExclusiveAccessContext::IsFullscreen() const { return false; }
void CobbleExclusiveAccessContext::EnterFullscreen(
    const url::Origin&, ExclusiveAccessBubbleType, FullscreenTabParams) {}
void CobbleExclusiveAccessContext::ExitFullscreen() {}
void CobbleExclusiveAccessContext::UpdateExclusiveAccessBubble(
    const ExclusiveAccessBubbleParams&,
    ExclusiveAccessBubbleHideCallback callback) {
  if (callback) {
    std::move(callback).Run(ExclusiveAccessBubbleHideReason::kNotShown);
  }
}
bool CobbleExclusiveAccessContext::IsExclusiveAccessBubbleDisplayed() const {
  return false;
}
void CobbleExclusiveAccessContext::OnExclusiveAccessUserInput() {}
content::WebContents*
CobbleExclusiveAccessContext::GetWebContentsForExclusiveAccess() {
  return browser_->tab_strip_model()->GetActiveWebContents();
}
bool CobbleExclusiveAccessContext::CanUserEnterFullscreen() const {
  // Until the host supplies an origin disclosure UI, denying fullscreen is
  // safer than entering an undisclosed exclusive-access state.
  return false;
}
bool CobbleExclusiveAccessContext::CanUserExitFullscreen() const { return true; }

CobbleModalDialogHost::CobbleModalDialogHost(Browser* browser)
    : browser_(browser) {}
CobbleModalDialogHost::~CobbleModalDialogHost() {
  for (auto& observer : observers_) {
    observer.OnHostDestroying();
  }
}
gfx::NativeView CobbleModalDialogHost::GetHostView() const {
  content::WebContents* contents =
      browser_->tab_strip_model()->GetActiveWebContents();
  return contents ? contents->GetNativeView() : gfx::NativeView();
}
gfx::Point CobbleModalDialogHost::GetDialogPosition(const gfx::Size& size) {
  gfx::Size host = GetMaximumDialogSize();
  return gfx::Point(std::max(0, (host.width() - size.width()) / 2),
                    std::max(0, (host.height() - size.height()) / 3));
}
gfx::Size CobbleModalDialogHost::GetMaximumDialogSize() {
  NSView* view = GetHostView().GetNativeNSView();
  return view ? gfx::Size(NSWidth(view.bounds), NSHeight(view.bounds))
              : gfx::Size(1280, 800);
}
void CobbleModalDialogHost::AddObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.AddObserver(observer);
}
void CobbleModalDialogHost::RemoveObserver(
    web_modal::ModalDialogHostObserver* observer) {
  observers_.RemoveObserver(observer);
}

CobbleBrowserWindow::CobbleBrowserWindow(Browser* browser)
    : browser_(browser),
      modal_dialog_host_(browser),
      exclusive_access_context_(browser),
      location_bar_(browser) {
  browser_->tab_strip_model()->AddObserver(this);
  cobble_chromium::RegisterBrowser(browser, this);
}
CobbleBrowserWindow::~CobbleBrowserWindow() {
  browser_->tab_strip_model()->RemoveObserver(this);
  cobble_chromium::UnregisterBrowser(browser_);
}

bool CobbleBrowserWindow::IsActive() const {
  return HostWindow(browser_).isKeyWindow;
}
bool CobbleBrowserWindow::IsMaximized() const {
  return HostWindow(browser_).zoomed;
}
bool CobbleBrowserWindow::IsMinimized() const {
  return HostWindow(browser_).miniaturized;
}
bool CobbleBrowserWindow::IsFullscreen() const {
  NSWindow* window = HostWindow(browser_);
  return window && (window.styleMask & NSWindowStyleMaskFullScreen);
}
gfx::NativeWindow CobbleBrowserWindow::GetNativeWindow() const {
  return gfx::NativeWindow(HostWindow(browser_));
}
gfx::Rect CobbleBrowserWindow::GetRestoredBounds() const {
  return BoundsForWindow(HostWindow(browser_));
}
ui::mojom::WindowShowState CobbleBrowserWindow::GetRestoredState() const {
  return ui::mojom::WindowShowState::kNormal;
}
gfx::Rect CobbleBrowserWindow::GetBounds() const {
  return BoundsForWindow(HostWindow(browser_));
}
void CobbleBrowserWindow::Show() { OnWindowDidShow(); }
void CobbleBrowserWindow::Hide() {}
bool CobbleBrowserWindow::IsVisible() const {
  return HostWindow(browser_).isVisible;
}
void CobbleBrowserWindow::ShowInactive() { OnWindowDidShow(); }
void CobbleBrowserWindow::Close() {
  UnloadController::From(browser_)->OnWindowClosing();
}
void CobbleBrowserWindow::Activate() {
  [HostWindow(browser_) makeKeyAndOrderFront:nil];
}
void CobbleBrowserWindow::Deactivate() { [HostWindow(browser_) resignKeyWindow]; }
void CobbleBrowserWindow::Maximize() { [HostWindow(browser_) zoom:nil]; }
void CobbleBrowserWindow::Minimize() { [HostWindow(browser_) miniaturize:nil]; }
void CobbleBrowserWindow::Restore() { [HostWindow(browser_) deminiaturize:nil]; }
void CobbleBrowserWindow::SetBounds(const gfx::Rect&) {}
void CobbleBrowserWindow::FlashFrame(bool flash) {
  if (flash) {
    [NSApp requestUserAttention:NSInformationalRequest];
  }
}
ui::ZOrderLevel CobbleBrowserWindow::GetZOrderLevel() const {
  return ui::ZOrderLevel::kNormal;
}
void CobbleBrowserWindow::SetZOrderLevel(ui::ZOrderLevel) {}
bool CobbleBrowserWindow::IsOnCurrentWorkspace() const { return true; }
bool CobbleBrowserWindow::IsVisibleOnScreen() const { return IsVisible(); }
void CobbleBrowserWindow::SetTopControlsShownRatio(content::WebContents*, float) {}
bool CobbleBrowserWindow::DoBrowserControlsShrinkRendererSize(
    const content::WebContents*) const { return false; }
ui::NativeTheme* CobbleBrowserWindow::GetNativeTheme() {
  return ui::NativeTheme::GetInstanceForNativeUi();
}
const ui::ThemeProvider* CobbleBrowserWindow::GetThemeProvider() const {
  return nullptr;
}
const ui::ColorProvider* CobbleBrowserWindow::GetColorProvider() const {
  return nullptr;
}
int CobbleBrowserWindow::GetTopControlsHeight() const { return 0; }
void CobbleBrowserWindow::SetTopControlsGestureScrollInProgress(bool) {}
std::vector<StatusBubble*> CobbleBrowserWindow::GetStatusBubbles() { return {}; }
void CobbleBrowserWindow::UpdateTitleBar() {
  if (content::WebContents* contents =
          browser_->tab_strip_model()->GetActiveWebContents()) {
    if (cobble_chromium::PageForWebContents(contents)) {
      // Title is emitted by WebContentsObserver; this covers tab activation.
      cobble_chromium::BrowserPageStateChanged(contents);
    }
  }
}
void CobbleBrowserWindow::UpdateLoadingAnimations(bool) {}
void CobbleBrowserWindow::OnActiveTabChanged(content::WebContents* old_contents,
                                             content::WebContents* new_contents,
                                             int, int) {
  cobble_chromium::BrowserActiveTabChanged(old_contents, new_contents);
}
void CobbleBrowserWindow::OnTabDetached(content::WebContents*, bool) {}
void CobbleBrowserWindow::OnTabStripModelChanged(
    TabStripModel*,
    const TabStripModelChange&,
    const TabStripSelectionChange&) {
  cobble_chromium::BrowserTabStripChanged(browser_);
}
gfx::Size CobbleBrowserWindow::GetContentsSize() const {
  content::WebContents* contents =
      browser_->tab_strip_model()->GetActiveWebContents();
  NSView* view = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  return view ? gfx::Size(NSWidth(view.bounds), NSHeight(view.bounds))
              : gfx::Size(1280, 800);
}
void CobbleBrowserWindow::SetContentsSize(const gfx::Size&) {}
autofill::AutofillBubbleHandler*
CobbleBrowserWindow::GetAutofillBubbleHandler() {
  static CobbleAutofillBubbleHandler* handler =
      new CobbleAutofillBubbleHandler();
  return handler;
}
LocationBar* CobbleBrowserWindow::GetLocationBar() const {
  return const_cast<CobbleLocationBar*>(&location_bar_);
}
void CobbleBrowserWindow::SetFocusToLocationBar(bool) {}
void CobbleBrowserWindow::UpdateReloadStopState(bool, bool) {}
void CobbleBrowserWindow::UpdateToolbar(content::WebContents*) {}
bool CobbleBrowserWindow::UpdateToolbarSecurityState() { return false; }
void CobbleBrowserWindow::UpdateCustomTabBarVisibility(bool, bool) {}
void CobbleBrowserWindow::ResetToolbarTabState(content::WebContents*) {}
void CobbleBrowserWindow::FocusToolbar() {}
void CobbleBrowserWindow::ToolbarSizeChanged(bool) {}
void CobbleBrowserWindow::TabDraggingStatusChanged(bool) {}
void CobbleBrowserWindow::LinkOpeningFromGesture(WindowOpenDisposition) {}
void CobbleBrowserWindow::FocusAppMenu() {}
bool CobbleBrowserWindow::IsTabStripEditable() const { return true; }
void CobbleBrowserWindow::DisableTabStripEditingForTesting() {}
bool CobbleBrowserWindow::IsToolbarVisible() const { return false; }
bool CobbleBrowserWindow::IsToolbarShowing() const { return false; }
bool CobbleBrowserWindow::IsLocationBarVisible() const { return false; }
void CobbleBrowserWindow::ShowUpdateChromeDialog() {}
void CobbleBrowserWindow::ShowIntentPickerBubble(
    std::vector<apps::IntentPickerAppInfo>, bool, bool,
    apps::IntentPickerBubbleType, const std::optional<url::Origin>&,
    IntentPickerResponse callback) {
  std::move(callback).Run(std::string(), apps::PickerEntryType::kUnknown,
                          apps::IntentPickerCloseReason::STAY_IN_CHROME,
                          false);
}
void CobbleBrowserWindow::ShowBookmarkBubble(const GURL&, bool) {}
ShowTranslateBubbleResult CobbleBrowserWindow::ShowTranslateBubble(
    content::WebContents*, translate::TranslateStep, const std::string&,
    const std::string&, translate::TranslateErrors, bool) { return {}; }
DownloadBubbleUIController*
CobbleBrowserWindow::GetDownloadBubbleUIController() { return nullptr; }
void CobbleBrowserWindow::ConfirmBrowserCloseWithPendingDownloads(
    int, UnloadController::DownloadCloseType,
    base::OnceCallback<void(bool)> callback) {
  // Cobble owns quit and download UX. Never close the native Browser from here.
  std::move(callback).Run(false);
}
void CobbleBrowserWindow::ShowAppMenu() {}
void CobbleBrowserWindow::PreHandleDragUpdate(const content::DropData&,
                                              const gfx::PointF&) {}
void CobbleBrowserWindow::PreHandleDragExit() {}
void CobbleBrowserWindow::HandleDragEnded() {}
content::KeyboardEventProcessingResult
CobbleBrowserWindow::PreHandleKeyboardEvent(
    const input::NativeWebKeyboardEvent&) {
  return content::KeyboardEventProcessingResult::NOT_HANDLED;
}
bool CobbleBrowserWindow::HandleKeyboardEvent(
    const input::NativeWebKeyboardEvent&) { return false; }
std::unique_ptr<FindBar> CobbleBrowserWindow::CreateFindBar() {
  return std::make_unique<CobbleFindBar>();
}
web_modal::WebContentsModalDialogHost*
CobbleBrowserWindow::GetWebContentsModalDialogHost() {
  return &modal_dialog_host_;
}
web_modal::WebContentsModalDialogHost*
CobbleBrowserWindow::GetWebContentsModalDialogHostFor(content::WebContents*) {
  return &modal_dialog_host_;
}
void CobbleBrowserWindow::ShowAvatarBubbleFromAvatarButton(bool) {}
void CobbleBrowserWindow::MaybeShowProfileSwitchIPH() {}
void CobbleBrowserWindow::MaybeShowSupervisedUserProfileSignInIPH() {}
void CobbleBrowserWindow::ShowHatsDialog(
    const std::string&, const std::optional<std::string>&,
    const std::optional<uint64_t>, base::OnceClosure,
    base::OnceClosure failure, const SurveyBitsData&,
    const SurveyStringData&) {
  if (failure) {
    std::move(failure).Run();
  }
}
ExclusiveAccessContext* CobbleBrowserWindow::GetExclusiveAccessContext() {
  return &exclusive_access_context_;
}
std::string CobbleBrowserWindow::GetWorkspace() const { return {}; }
bool CobbleBrowserWindow::IsVisibleOnAllWorkspaces() const { return false; }
void CobbleBrowserWindow::ShowEmojiPanel() {
  [NSApp orderFrontCharacterPalette:nil];
}
std::unique_ptr<content::EyeDropper> CobbleBrowserWindow::OpenEyeDropper(
    content::RenderFrameHost*, content::EyeDropperListener*) { return nullptr; }
void CobbleBrowserWindow::ShowCaretBrowsingDialog() {}
void CobbleBrowserWindow::CreateTabSearchBubble() {}
void CobbleBrowserWindow::CloseTabSearchBubble() {}
void CobbleBrowserWindow::ShowIncognitoClearBrowsingDataDialog() {}
void CobbleBrowserWindow::ShowIncognitoHistoryDisclaimerDialog() {}
bool CobbleBrowserWindow::IsUnframedModeEnabled() const { return false; }
bool CobbleBrowserWindow::GetCanResize() { return true; }
ui::mojom::WindowShowState CobbleBrowserWindow::GetWindowShowState() const {
  if (IsFullscreen()) return ui::mojom::WindowShowState::kFullscreen;
  if (IsMinimized()) return ui::mojom::WindowShowState::kMinimized;
  if (IsMaximized()) return ui::mojom::WindowShowState::kMaximized;
  return ui::mojom::WindowShowState::kNormal;
}
void CobbleBrowserWindow::ShowChromeLabs() {}
BrowserView* CobbleBrowserWindow::AsBrowserView() { return nullptr; }
void CobbleBrowserWindow::OnWindowDidShow() {
  if (window_has_shown_) {
    return;
  }
  window_has_shown_ = true;

  startup_metric_utils::GetBrowser().RecordBrowserWindowDisplay(
      base::TimeTicks::Now());

  if (browser_->GetType() != BrowserWindowInterface::Type::TYPE_NORMAL) {
    return;
  }

  GlobalErrorService* service =
      GlobalErrorServiceFactory::GetForProfile(browser_->GetProfile());
  GlobalError* error = service->GetFirstGlobalErrorWithBubbleView();
  if (error) {
    error->ShowBubbleView(browser_);
  }
}
void CobbleBrowserWindow::DeleteBrowserWindow() {
  // Match BrowserWidget: features retain references to the native window and
  // must release them while the window and its contexts are still alive.
  browser_->GetFeatures().TearDownPreBrowserWindowDestruction();
  delete this;
}
