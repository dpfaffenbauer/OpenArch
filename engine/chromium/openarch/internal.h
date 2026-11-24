// Shared between the bridge's files (OACEngine, OACProfile, OACPane on
// Chrome's framework).

#ifndef OPENARCH_INTERNAL_H_
#define OPENARCH_INTERNAL_H_

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

// OACApplication is a BrowserCrApplication on Chrome's framework.
#import "chrome/browser/chrome_browser_application_mac.h"
#define OAC_APPLICATION_SUPERCLASS BrowserCrApplication
#import "openarch/include/OACEngine.h"
#import "openarch/include/OACPane.h"
#import "openarch/include/OACProfile.h"

class BrowserWindowInterface;
class Profile;
@class NSWindow;

namespace content {
class WebContents;
}
namespace web_modal {
class WebContentsModalDialogHost;
}

@interface OACProfile (Internal)
/// Chrome's profile, once loaded (nullptr before).
- (Profile*)chromeProfile;
/// Loads the profile if needed, then runs |block| with it (nullptr when it
/// could not be loaded).
- (void)withChromeProfile:(void (^)(Profile* profile))block;
@end

namespace openarch {

// Start-up: OACEngine's ready blocks, run in PostBrowserStart.
void RunReadyBlocks();
// The message loop ended: panes and profiles let go of Chrome's objects.
void StopBridge();
bool IsReady();

// The command line ChromeMain gets: the app's own arguments plus what
// OACEngineSettings asked for.
std::vector<std::string> EngineArguments(int argc, const char** argv);

// Chrome's hooks for OpenArch's pages: new tabs, keys, link throttle.
void InstallPaneHooks();

// The pane showing |contents|, if OpenArch shows it.
OACPane* PaneForWebContents(content::WebContents* contents);

// Chrome docked DevTools for a page of |browser| (opened by Chrome itself:
// Inspect, the console, its own shortcut): the pane shows them beside the
// page.
void AdoptDockedDevTools(BrowserWindowInterface* browser);

// A page's full screen: its own window on its own full screen space. Enter
// returns false when OpenArch does not show |contents|.
bool EnterPageFullScreen(content::WebContents* contents);
void ExitPageFullScreen(content::WebContents* contents);
bool IsPageFullScreen(content::WebContents* contents);

// dialogs.mm: OpenArch's window hosts the page's dialogs and permission
// prompts; the hooks for JavaScript dialogs and permission prompts.
NSWindow* DialogWindowForPane(OACPane* pane);
void HostDialogsInPane(content::WebContents* contents, OACPane* pane);
void StopHostingDialogs(content::WebContents* contents);
// The host of |contents|' tab-modal dialogs (FedCM sign-in, ...), for
// Chrome's window: the pane's, or one over the main window; never null.
web_modal::WebContentsModalDialogHost* DialogHostForContents(content::WebContents* contents);
void InstallDialogHooks();

// The Browser whose tab strip holds a profile's pages (with OpenArch's own
// window, page_window.h). Made on first use, again after it closed.
BrowserWindowInterface* HiddenBrowserForProfile(Profile* profile);

// The OpenArch window a Browser's pages are shown in (for Chrome's
// dialogs, focus and bounds), and the page of it the user is in.
NSWindow* HostWindowForBrowser(BrowserWindowInterface* browser);
content::WebContents* FocusedContentsForBrowser(BrowserWindowInterface* browser);

std::string ToStdString(NSString* string);
NSString* ToNSString(const std::string& string);
NSString* ToNSString(const std::u16string& string);

}  // namespace openarch

#endif  // OPENARCH_INTERNAL_H_
