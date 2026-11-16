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

// dialogs.mm: OpenArch's window hosts the page's dialogs and permission
// prompts; the hooks for JavaScript dialogs and permission prompts.
NSWindow* DialogWindowForPane(OACPane* pane);
void HostDialogsInPane(content::WebContents* contents, OACPane* pane);
void StopHostingDialogs(content::WebContents* contents);
void InstallDialogHooks();

// The hidden Chrome window (a normal browser window) whose tab strip holds a
// profile's pages. Made on first use, again after Chrome closed it.
BrowserWindowInterface* HiddenBrowserForProfile(Profile* profile);

std::string ToStdString(NSString* string);
NSString* ToNSString(const std::string& string);
NSString* ToNSString(const std::u16string& string);

}  // namespace openarch

#endif  // OPENARCH_INTERNAL_H_
