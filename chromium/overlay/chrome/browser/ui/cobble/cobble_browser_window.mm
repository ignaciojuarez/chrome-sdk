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
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
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

// Moves one page view into its own native fullscreen Space, as WebKit does,
// and returns it to its Cobble container afterwards. The window keeps a
// hidden titlebar because macOS fullscreen Spaces require a titled window.
// The page view claims every key equivalent for the renderer, and Cobble routes
// browser shortcuts only in its own windows. Offer them to the menu first so
// Exit Full Screen, Quit and editing commands keep working.
@interface CobbleContentFullscreenWindow : NSWindow
@end

@implementation CobbleContentFullscreenWindow
- (BOOL)performKeyEquivalent:(NSEvent*)event {
  return [NSApp.mainMenu performKeyEquivalent:event] ||
         [super performKeyEquivalent:event];
}
@end

@interface CobbleContentFullscreenController : NSObject <NSWindowDelegate>
@property(nonatomic, readonly, getter=isActive) BOOL active;
- (instancetype)initWithPage:(NSView*)page
                      origin:(NSString*)origin
                    onChange:(void (^)(void))onChange
                  onUserExit:(void (^)(void))onUserExit;
- (void)exitFullscreen;
// Restores the page synchronously without calling back into Chromium.
- (void)abandon;
@end

@implementation CobbleContentFullscreenController {
  NSWindow* __strong _window;
  NSView* __strong _page;
  NSView* __weak _home;
  NSString* __strong _origin;
  void (^_onChange)(void);
  void (^_onUserExit)(void);
  BOOL _entering;
  BOOL _exiting;
}

- (instancetype)initWithPage:(NSView*)page
                      origin:(NSString*)origin
                    onChange:(void (^)(void))onChange
                  onUserExit:(void (^)(void))onUserExit {
  if ((self = [super init])) {
    _page = page;
    _home = page.superview;
    _origin = origin;
    _onChange = [onChange copy];
    _onUserExit = [onUserExit copy];
    _entering = YES;
    const NSRect frame = page.window ? page.window.frame
                                     : NSScreen.mainScreen.frame;
    _window = [[CobbleContentFullscreenWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskFullSizeContentView
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.releasedWhenClosed = NO;
    _window.title = origin ?: @"";
    _window.titleVisibility = NSWindowTitleHidden;
    _window.titlebarAppearsTransparent = YES;
    _window.backgroundColor = NSColor.blackColor;
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.tabbingMode = NSWindowTabbingModeDisallowed;
    _window.delegate = self;
    [_window setFrame:frame display:NO];
    for (NSWindowButton button : {NSWindowCloseButton,
                                  NSWindowMiniaturizeButton,
                                  NSWindowZoomButton}) {
      [_window standardWindowButton:button].hidden = YES;
    }
    [page removeFromSuperview];
    page.frame = _window.contentView.bounds;
    page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_window.contentView addSubview:page];
    [_window makeKeyAndOrderFront:nil];
    [_window toggleFullScreen:nil];
  }
  return self;
}

- (BOOL)isActive {
  return _window != nil;
}

- (void)exitFullscreen {
  if (!_window || _exiting) {
    return;
  }
  _exiting = YES;
  if (_entering) {
    return;  // The enter transition's completion finishes the exit.
  }
  if (_window.styleMask & NSWindowStyleMaskFullScreen) {
    [_window toggleFullScreen:nil];
  } else {
    [self finish];
  }
}

- (void)abandon {
  _onChange = nil;
  _onUserExit = nil;
  [self restore];
}

// Returns whether the page went back into its Cobble container.
- (BOOL)restore {
  NSWindow* window = _window;
  if (!window) {
    return NO;
  }
  BOOL restored = NO;
  _window = nil;
  window.delegate = nil;
  if (_page.window == window) {
    [_page removeFromSuperview];
    // If Cobble mounted another page meanwhile, it remounts this one later.
    NSView* home = _home;
    if (home && home.subviews.count == 0) {
      _page.frame = home.bounds;
      _page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      [home addSubview:_page];
      restored = YES;
    }
  }
  [window orderOut:nil];
  [window close];
  return restored;
}

- (void)finish {
  if ([self restore]) {
    [_page.window makeKeyAndOrderFront:nil];
  }
  if (_onChange) {
    _onChange();
  }
}

- (void)showDisclosure {
  NSString* text =
      _origin.length
          ? [NSString stringWithFormat:@"%@ is full screen. Press Esc to exit.",
                                       _origin]
          : @"This page is full screen. Press Esc to exit.";
  NSTextField* label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  const NSSize size = label.fittingSize;
  NSVisualEffectView* banner = [[NSVisualEffectView alloc]
      initWithFrame:NSMakeRect(0, 0, size.width + 32, size.height + 16)];
  banner.material = NSVisualEffectMaterialHUDWindow;
  banner.blendingMode = NSVisualEffectBlendingModeWithinWindow;
  banner.state = NSVisualEffectStateActive;
  banner.wantsLayer = YES;
  banner.layer.cornerRadius = 10;
  label.frameOrigin = NSMakePoint(16, 8);
  [banner addSubview:label];
  NSView* content = _window.contentView;
  banner.frameOrigin =
      NSMakePoint(NSMidX(content.bounds) - NSWidth(banner.frame) / 2,
                  NSMaxY(content.bounds) - NSHeight(banner.frame) - 48);
  banner.autoresizingMask =
      NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
  [content addSubview:banner];
  NSAccessibilityPostNotificationWithUserInfo(
      NSApp, NSAccessibilityAnnouncementRequestedNotification,
      @{NSAccessibilityAnnouncementKey: text,
        NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
  NSView* __weak weakBanner = banner;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
      dispatch_get_main_queue(), ^{
        [NSAnimationContext
            runAnimationGroup:^(NSAnimationContext* context) {
              context.duration = 0.3;
              weakBanner.animator.alphaValue = 0;
            }
            completionHandler:^{
              [weakBanner removeFromSuperview];
            }];
      });
}

- (void)windowDidEnterFullScreen:(NSNotification*)notification {
  _entering = NO;
  if (_exiting) {
    [_window toggleFullScreen:nil];
    return;
  }
  [self showDisclosure];
  if (_onChange) {
    _onChange();
  }
}

- (void)windowDidFailToEnterFullScreen:(NSWindow*)window {
  _entering = NO;
  [self finish];
}

- (void)windowWillExitFullScreen:(NSNotification*)notification {
  if (_exiting) {
    return;
  }
  // The user left the Space with the menu, a gesture, or Mission Control.
  _exiting = YES;
  if (_onUserExit) {
    _onUserExit();
  }
}

- (void)windowDidExitFullScreen:(NSNotification*)notification {
  [self finish];
}

- (void)windowDidFailToExitFullScreen:(NSWindow*)window {
  [self finish];
}

@end

class CobbleContentFullscreen {
 public:
  explicit CobbleContentFullscreen(CobbleContentFullscreenController* controller)
      : controller_(controller) {}
  ~CobbleContentFullscreen() { [controller_ abandon]; }
  CobbleContentFullscreenController* controller() const { return controller_; }

 private:
  CobbleContentFullscreenController* __strong controller_;
};

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
CobbleExclusiveAccessContext::~CobbleExclusiveAccessContext() = default;
Profile* CobbleExclusiveAccessContext::GetProfile() {
  return browser_->GetProfile();
}
bool CobbleExclusiveAccessContext::IsFullscreen() const {
  // Cobble owns window fullscreen; this reports page fullscreen only, so a
  // page can still enter its own Space from a fullscreen Cobble window.
  return fullscreen_ && [fullscreen_->controller() isActive];
}
void CobbleExclusiveAccessContext::EnterFullscreen(
    const url::Origin& origin, ExclusiveAccessBubbleType, FullscreenTabParams) {
  content::WebContents* contents = GetWebContentsForExclusiveAccess();
  NSView* page = contents ? contents->GetNativeView().GetNativeNSView() : nil;
  if (IsFullscreen() || !page.superview) {
    return;
  }
  Browser* browser = browser_;
  base::WeakPtr<content::WebContents> weak_contents = contents->GetWeakPtr();
  const std::string host = origin.host();
  fullscreen_ = std::make_unique<CobbleContentFullscreen>(
      [[CobbleContentFullscreenController alloc]
          initWithPage:page
                origin:host.empty() ? nil : base::SysUTF8ToNSString(host)
              onChange:^{
                if (weak_contents) {
                  weak_contents->Focus();
                }
                if (ExclusiveAccessManager* manager =
                        browser->GetFeatures().exclusive_access_manager()) {
                  manager->fullscreen_controller()
                      ->WindowFullscreenStateChanged();
                }
              }
            onUserExit:^{
              if (ExclusiveAccessManager* manager =
                      browser->GetFeatures().exclusive_access_manager()) {
                manager->ExitExclusiveAccess();
              }
            }]);
  contents->Focus();
}
void CobbleExclusiveAccessContext::ExitFullscreen() {
  if (fullscreen_) {
    [fullscreen_->controller() exitFullscreen];
  }
}
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
  // Cobble owns browser-window fullscreen. Page fullscreen does not use this.
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
