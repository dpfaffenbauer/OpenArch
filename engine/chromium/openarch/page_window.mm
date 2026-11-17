#import "openarch/page_window.h"

#import <AppKit/AppKit.h>

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/autofill/autofill_bubble_base.h"
#include "chrome/browser/ui/autofill/autofill_bubble_handler.h"
#include "chrome/browser/ui/autofill/save_address_bubble_controller.h"
#include "chrome/browser/ui/autofill/update_address_bubble_controller.h"
#include "chrome/browser/ui/browser_manager_service.h"
#include "chrome/browser/ui/browser_window.h"
#include "chrome/browser/ui/browser_window/public/browser_window_features.h"
#include "chrome/browser/ui/browser_window/public/browser_window_interface.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_context.h"
#include "chrome/browser/ui/exclusive_access/exclusive_access_manager.h"
#include "chrome/browser/ui/exclusive_access/fullscreen_controller.h"
#include "chrome/browser/ui/find_bar/find_bar.h"
#include "chrome/browser/ui/location_bar/location_bar.h"
#include "chrome/browser/ui/views/bubble_anchor_util_views.h"
#include "components/find_in_page/find_notification_details.h"
#include "ui/gfx/range/range.h"
#include "chrome/browser/ui/tabs/tab_strip_model.h"
#include "chrome/browser/ui/unload_controller.h"
#include "components/signin/public/base/signin_buildflags.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/web_contents.h"
#include "openarch/internal.h"
#include "ui/base/mojom/window_show_state.mojom.h"
#include "ui/color/color_provider_key.h"
#include "ui/color/color_provider_manager.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/mac/coordinate_conversion.h"
#include "ui/gfx/native_ui_types.h"

namespace openarch {
namespace {

// Autofill's bubbles (save a card, an address, ...) have no window to hang
// from; their controllers get a bubble that is never shown.
class SilentBubble : public autofill::AutofillBubbleBase {
 public:
  void Hide() override {}
  bool IsMouseHovered() const override { return false; }
};

class SilentAutofillBubbles : public autofill::AutofillBubbleHandler {
 public:
  using Bubble = autofill::AutofillBubbleBase;
  Bubble* ShowSaveCreditCardBubble(content::WebContents*,
                                   autofill::SaveCardBubbleController*,
                                   bool) override {
    return &bubble_;
  }
  Bubble* ShowIbanBubble(content::WebContents*,
                         autofill::IbanBubbleController*,
                         bool,
                         autofill::IbanBubbleType) override {
    return &bubble_;
  }
  Bubble* ShowOfferNotificationBubble(content::WebContents*,
                                      autofill::OfferNotificationBubbleController*,
                                      bool) override {
    return &bubble_;
  }
  Bubble* ShowSaveAutofillAiDataBubble(content::WebContents*,
                                       autofill::AutofillAiImportDataController*) override {
    return &bubble_;
  }
  Bubble* ShowAutofillAiLocalSaveNotification(
      content::WebContents*,
      autofill::AutofillAiImportDataController*) override {
    return &bubble_;
  }
  Bubble* ShowSaveAddressProfileBubble(
      content::WebContents*,
      std::unique_ptr<autofill::SaveAddressBubbleController>,
      bool) override {
    return &bubble_;
  }
  Bubble* ShowUpdateAddressProfileBubble(
      content::WebContents*,
      std::unique_ptr<autofill::UpdateAddressBubbleController>,
      bool) override {
    return &bubble_;
  }
#if BUILDFLAG(ENABLE_DICE_SUPPORT)
  Bubble* ShowAddressSignInPromo(content::WebContents*,
                                 const autofill::AutofillProfile&) override {
    return &bubble_;
  }
#endif
  Bubble* ShowFilledCardInformationBubble(content::WebContents*,
                                          autofill::FilledCardInformationBubbleController*,
                                          bool) override {
    return &bubble_;
  }
  Bubble* ShowVirtualCardEnrollBubble(content::WebContents*,
                                      autofill::VirtualCardEnrollBubbleController*,
                                      bool) override {
    return &bubble_;
  }
  Bubble* ShowVirtualCardEnrollConfirmationBubble(
      content::WebContents*,
      autofill::VirtualCardEnrollBubbleController*) override {
    return &bubble_;
  }
  Bubble* ShowMandatoryReauthBubble(content::WebContents*,
                                    autofill::MandatoryReauthBubbleController*,
                                    bool,
                                    autofill::MandatoryReauthBubbleType) override {
    return &bubble_;
  }
  Bubble* ShowSaveCardConfirmationBubble(content::WebContents*,
                                         autofill::SaveCardBubbleController*) override {
    return &bubble_;
  }
  Bubble* ShowSaveIbanConfirmationBubble(content::WebContents*,
                                         autofill::IbanBubbleController*) override {
    return &bubble_;
  }
  Bubble* ShowOmniboxAutofillBubble(content::WebContents*,
                                    autofill::OmniboxAutofillBubbleController*) override {
    return &bubble_;
  }
  Bubble* ShowPaymentsChurnedUsersBubble(content::WebContents*,
                                         autofill::PaymentsChurnedUsersBubbleController*,
                                         bool) override {
    return &bubble_;
  }
  Bubble* ShowPaymentsChurnedUsersConfirmationBubble(
      content::WebContents*,
      autofill::PaymentsChurnedUsersBubbleController*) override {
    return &bubble_;
  }
  Bubble* ShowWalletReminderNoticeBubble(content::WebContents*,
                                         autofill::WalletReminderNoticeBubbleController*,
                                         bool) override {
    return &bubble_;
  }

 private:
  SilentBubble bubble_;
};

// Chrome's find bar for a page: OpenArch's own bar (findbar.mm) does the
// finding with Chrome's FindTabHelper; Chrome's controller gets a bar that
// shows nothing (it asks for one when a tab with a search going on joins
// the tab strip).
class SilentFindBar : public FindBar {
 public:
  FindBarController* GetFindBarController() const override { return controller_; }
  void SetFindBarController(FindBarController* controller) override { controller_ = controller; }
  void Show(bool, bool) override {}
  void Hide(bool) override {}
  void SetFocusAndSelection() override {}
  void ClearResults(const find_in_page::FindNotificationDetails&) override {}
  void StopAnimation() override {}
  void MoveWindowIfNecessary() override {}
  void SetFindTextAndSelectedRange(const std::u16string& text, const gfx::Range& range) override {
    text_ = text;
    range_ = range;
  }
  std::u16string_view GetFindText() const override { return text_; }
  gfx::Range GetSelectedRange() const override { return range_; }
  void UpdateUIForFindResult(const find_in_page::FindNotificationDetails&,
                             const std::u16string&) override {}
  void AudibleAlert() override {}
  bool IsFindBarVisible() const override { return false; }
  void RestoreSavedFocus() override {}
  bool HasGlobalFindPasteboard() const override { return false; }
  void UpdateFindBarForChangedWebContents() override {}
  bool CanPopulateFromSelectedText() override { return false; }
  const FindBarTesting* GetFindBarTesting() const override { return nullptr; }
  bool HasFocus() const override { return false; }
  void CloseOverlappingBubbles() override {}
  views::Widget* GetHostWidget() override { return nullptr; }

 private:
  raw_ptr<FindBarController> controller_ = nullptr;
  std::u16string text_;
  gfx::Range range_;
};

// The location bar of a window without a toolbar: OpenArch's own address
// field lives in its sidebar, so Chrome's calls (saving the omnibox state on
// a tab switch, updating icons) have nothing to act on.
class SilentLocationBar : public LocationBar {
 public:
  explicit SilentLocationBar(BrowserWindowInterface* browser)
      : LocationBar(/*command_updater=*/nullptr), browser_(browser) {}

  void FocusLocation(bool, bool) override {}
  void FocusSearch() override {}
  void UpdateFocusBehavior(bool) override {}
  void UpdateContentSettingsIcons() override {}
  void SaveStateToContents(content::WebContents*) override {}
  void Revert() override {}
  OmniboxView* GetOmniboxView() override { return nullptr; }
  OmniboxPopupView* GetOmniboxPopupView() override { return nullptr; }
  OmniboxController* GetOmniboxController() override { return nullptr; }
  bool ShouldCloseOmniboxPopup(ui::MouseEvent*) override { return false; }
  content::WebContents* GetWebContents() override {
    return browser_->GetTabStripModel()->GetActiveWebContents();
  }
  LocationBarModel* GetLocationBarModel() override { return nullptr; }
  std::optional<bubble_anchor_util::AnchorConfiguration> GetChipAnchor() override {
    return std::nullopt;
  }
  ChipController* GetChipController() override { return nullptr; }
  void AnnounceAlert(const std::u16string&) override {}
  void OnChanged() override {}
  void UpdateWithoutTabRestore() override {}
  ui::TrackedElement* GetAnchorOrNull() override { return nullptr; }
  BrowserWindowInterface* GetBrowser() override { return browser_; }
  Profile* GetProfile() override { return browser_->GetProfile(); }
  bool IsInitialized() const override { return true; }
  bool IsVisible() const override { return false; }
  bool IsDrawn() const override { return false; }
  bool IsFullscreen() const override { return false; }
  bool IsEditingOrEmpty() const override { return false; }
  bool IsMouseHovered() const override { return false; }
  bool IsFocusWithin() const override { return false; }
  void InvalidateLayout() override {}
  gfx::Rect Bounds() const override { return gfx::Rect(); }
  gfx::Rect BoundsInScreen() const override { return gfx::Rect(); }
  gfx::Size MinimumSize() const override { return gfx::Size(); }
  gfx::Size PreferredSize() const override { return gfx::Size(); }
  void Update(content::WebContents*) override {}
  void ResetTabState(content::WebContents*) override {}
  bool HasSecurityStateChanged() override { return false; }
  LocationBarTesting* GetLocationBarForTesting() override { return nullptr; }

 private:
  raw_ptr<BrowserWindowInterface> browser_;
};

// Full screen for a page: the page gets a window of its own on its own full
// screen space (pane.mm); OpenArch's window stays as it is.
class PageExclusiveAccess : public ExclusiveAccessContext {
 public:
  explicit PageExclusiveAccess(BrowserWindowInterface* browser) : browser_(browser) {}

  Profile* GetProfile() override { return browser_->GetProfile(); }
  bool IsFullscreen() const override { return IsPageFullScreen(fullscreen_contents_.get()); }
  void EnterFullscreen(const url::Origin&, ExclusiveAccessBubbleType, FullscreenTabParams) override {
    content::WebContents* contents = RequestingContents();
    if (contents && EnterPageFullScreen(contents)) {
      fullscreen_contents_ = contents->GetWeakPtr();
    }
  }
  // The page that went full screen: on the Mac Chrome forgets which tab it
  // was before it asks to leave.
  void ExitFullscreen() override { ExitPageFullScreen(fullscreen_contents_.get()); }
  void UpdateExclusiveAccessBubble(const ExclusiveAccessBubbleParams&,
                                   ExclusiveAccessBubbleHideCallback callback) override {
    if (callback) {
      std::move(callback).Run(ExclusiveAccessBubbleHideReason::kNotShown);
    }
  }
  bool IsExclusiveAccessBubbleDisplayed() const override { return false; }

  // The page that asks for full screen, else the focused one.
  content::WebContents* RequestingContents() const {
    if (auto* manager = ExclusiveAccessManager::From(browser_)) {
      if (content::WebContents* tab = manager->fullscreen_controller()->exclusive_access_tab()) {
        return tab;
      }
    }
    return FocusedContentsForBrowser(browser_);
  }
  void OnExclusiveAccessUserInput() override {}
  content::WebContents* GetWebContentsForExclusiveAccess() override {
    return FocusedContentsForBrowser(browser_);
  }
  bool CanUserEnterFullscreen() const override { return true; }
  bool CanUserExitFullscreen() const override { return true; }

 private:
  raw_ptr<BrowserWindowInterface> browser_;
  base::WeakPtr<content::WebContents> fullscreen_contents_;
};

class PageWindow : public BrowserWindow {
 public:
  explicit PageWindow(BrowserWindowInterface* browser)
      : browser_(browser), location_bar_(browser), exclusive_access_(browser) {}
  // Chrome's own windows tear the window features down before they go (the
  // Browser deletes them afterwards); several of them observe each other and
  // must not outlive what they observe.
  ~PageWindow() override { browser_->GetFeatures().TearDownPreBrowserWindowDestruction(); }

  // ui::BaseWindow: the OpenArch window the Browser's pages are shown in.
  bool IsActive() const override {
    NSWindow* window = Host();
    return window && window.isKeyWindow && NSApp.isActive;
  }
  bool IsMaximized() const override { return false; }
  bool IsMinimized() const override { return Host().miniaturized; }
  bool IsFullscreen() const override { return exclusive_access_.IsFullscreen(); }
  gfx::NativeWindow GetNativeWindow() const override { return gfx::NativeWindow(Host()); }
  gfx::Rect GetRestoredBounds() const override { return GetBounds(); }
  ui::mojom::WindowShowState GetRestoredState() const override {
    return ui::mojom::WindowShowState::kNormal;
  }
  gfx::Rect GetBounds() const override {
    NSWindow* window = Host();
    return window ? gfx::ScreenRectFromNSRect(window.frame) : gfx::Rect();
  }
  // Chrome's window is never shown, hidden, moved or activated: OpenArch's
  // windows do that themselves.
  void Show() override {}
  void Hide() override {}
  bool IsVisible() const override { return true; }
  void ShowInactive() override {}
  void Close() override;
  void Activate() override {}
  void Deactivate() override {}
  void Maximize() override {}
  void Minimize() override {}
  void Restore() override {}
  void SetBounds(const gfx::Rect&) override {}
  void FlashFrame(bool) override {}
  ui::ZOrderLevel GetZOrderLevel() const override { return ui::ZOrderLevel::kNormal; }
  void SetZOrderLevel(ui::ZOrderLevel) override {}

  // BrowserWindow.
  bool IsOnCurrentWorkspace() const override { return true; }
  bool IsVisibleOnScreen() const override { return true; }
  void SetTopControlsShownRatio(content::WebContents*, float) override {}
  bool DoBrowserControlsShrinkRendererSize(const content::WebContents*) const override {
    return false;
  }
  ui::NativeTheme* GetNativeTheme() override { return nullptr; }
  const ui::ThemeProvider* GetThemeProvider() const override { return nullptr; }
  const ui::ColorProvider* GetColorProvider() const override {
    return ui::ColorProviderManager::Get().GetColorProviderFor(ui::ColorProviderKey());
  }
  int GetTopControlsHeight() const override { return 0; }
  void SetTopControlsGestureScrollInProgress(bool) override {}
  std::vector<StatusBubble*> GetStatusBubbles() override { return {}; }
  void UpdateTitleBar() override {}
  void UpdateLoadingAnimations(bool) override {}
  void OnActiveTabChanged(content::WebContents*, content::WebContents*, int, int) override {}
  void OnTabDetached(content::WebContents*, bool) override {}
  gfx::Size GetContentsSize() const override {
    content::WebContents* contents = browser_->GetTabStripModel()->GetActiveWebContents();
    return contents ? contents->GetContainerBounds().size() : gfx::Size();
  }
  void SetContentsSize(const gfx::Size&) override {}
  autofill::AutofillBubbleHandler* GetAutofillBubbleHandler() override { return &autofill_; }
  LocationBar* GetLocationBar() const override {
    return const_cast<SilentLocationBar*>(&location_bar_);
  }
  ui::AcceleratorProvider* GetAcceleratorProvider() override { return nullptr; }
  PinnedToolbarActions* GetPinnedToolbarActions() override { return nullptr; }
  void SetFocusToLocationBar(bool) override {}
  void UpdateReloadStopState(bool, bool) override {}
  void UpdateToolbar(content::WebContents*) override {}
  bool UpdateToolbarSecurityState() override { return false; }
  void UpdateCustomTabBarVisibility(bool, bool) override {}
  void ResetToolbarTabState(content::WebContents*) override {}
  void FocusToolbar() override {}
  void ToolbarSizeChanged(bool) override {}
  void TabDraggingStatusChanged(bool) override {}
  void LinkOpeningFromGesture(WindowOpenDisposition) override {}
  void FocusAppMenu() override {}
  bool IsTabStripEditable() const override { return true; }
  void DisableTabStripEditingForTesting() override {}
  bool IsToolbarVisible() const override { return false; }
  bool IsToolbarShowing() const override { return false; }
  bool IsLocationBarVisible() const override { return false; }
  void ShowUpdateChromeDialog() override {}
  void ShowIntentPickerBubble(std::vector<apps::IntentPickerAppInfo>,
                              bool,
                              bool,
                              apps::IntentPickerBubbleType,
                              const std::optional<url::Origin>&,
                              IntentPickerResponse) override {}
  void ShowBookmarkBubble(const GURL&, bool) override {}
  ShowTranslateBubbleResult ShowTranslateBubble(content::WebContents*,
                                                translate::TranslateStep,
                                                const std::string&,
                                                const std::string&,
                                                translate::TranslateErrors,
                                                bool) override {
    return ShowTranslateBubbleResult::kBrowserWindowNotValid;
  }
  DownloadBubbleUIController* GetDownloadBubbleUIController() override { return nullptr; }
  // Downloads going on when the last page closes (at quit) go on closing.
  void ConfirmBrowserCloseWithPendingDownloads(int,
                                               UnloadController::DownloadCloseType,
                                               base::OnceCallback<void(bool)> callback) override {
    std::move(callback).Run(true);
  }
  void ShowAppMenu() override {}
  void PreHandleDragUpdate(const content::DropData&, const gfx::PointF&) override {}
  void PreHandleDragExit() override {}
  void HandleDragEnded() override {}
  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      const input::NativeWebKeyboardEvent&) override {
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }
  bool HandleKeyboardEvent(const input::NativeWebKeyboardEvent&) override { return false; }
  std::unique_ptr<FindBar> CreateFindBar() override { return std::make_unique<SilentFindBar>(); }
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost() override {
    return nullptr;
  }
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHostFor(
      content::WebContents*) override {
    return nullptr;
  }
  void ShowAvatarBubbleFromAvatarButton(bool) override {}
  void ShowHatsDialog(const std::string&,
                      const std::optional<std::string>&,
                      const std::optional<uint64_t>,
                      base::OnceClosure,
                      base::OnceClosure failure_callback,
                      const SurveyBitsData&,
                      const SurveyStringData&) override {
    std::move(failure_callback).Run();
  }
  ExclusiveAccessContext* GetExclusiveAccessContext() override { return &exclusive_access_; }
  std::string GetWorkspace() const override { return std::string(); }
  bool IsVisibleOnAllWorkspaces() const override { return false; }
  void ShowEmojiPanel() override { [NSApp orderFrontCharacterPalette:nil]; }
  std::unique_ptr<content::EyeDropper> OpenEyeDropper(content::RenderFrameHost*,
                                                      content::EyeDropperListener*) override {
    return nullptr;
  }
  void ShowCaretBrowsingDialog() override {}
  void CreateTabSearchBubble() override {}
  void CloseTabSearchBubble() override {}
  void ShowIncognitoClearBrowsingDataDialog() override {}
  void ShowIncognitoHistoryDisclaimerDialog() override {}
  bool IsUnframedModeEnabled() const override { return false; }
  bool GetCanResize() override { return false; }
  ui::mojom::WindowShowState GetWindowShowState() const override {
    return ui::mojom::WindowShowState::kNormal;
  }
  void ShowChromeLabs() override {}
  BrowserView* AsBrowserView() override { return nullptr; }

 protected:
  void DeleteBrowserWindow() override { delete this; }

 private:
  NSWindow* Host() const { return HostWindowForBrowser(browser_); }

  raw_ptr<BrowserWindowInterface> browser_;
  SilentAutofillBubbles autofill_;
  SilentLocationBar location_bar_;
  PageExclusiveAccess exclusive_access_;
  bool destroying_ = false;
};

// As Chrome's window closing: beforeunload handlers first, then the tabs
// close; once the tab strip is empty (Chrome calls Close again), the Browser
// is destroyed, which deletes this window.
void PageWindow::Close() {
  if (destroying_) {
    return;
  }
  UnloadController* unload = UnloadController::From(browser_);
  if (!unload->HandleBeforeClose()) {
    return;
  }
  unload->OnWindowClosing();
  if (!browser_->GetTabStripModel()->empty()) {
    return;
  }
  destroying_ = true;
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<BrowserWindowInterface> browser) {
                       if (browser) {
                         BrowserManagerService::SynchronouslyDestroyBrowser(browser.get());
                       }
                     },
                     browser_->GetWeakPtr()));
}

}  // namespace

BrowserWindow* MakePageWindow(BrowserWindowInterface* browser) {
  return new PageWindow(browser);
}

}  // namespace openarch
