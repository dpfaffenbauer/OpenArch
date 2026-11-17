// The window of a Chrome Browser that holds OpenArch's pages: a
// BrowserWindow of OpenArch's own, without a native window, a BrowserView,
// a tab strip or a toolbar. The Browser keeps its tabs (chrome.tabs,
// popups, extensions, permission prompts work as in Chrome); whatever
// Chrome asks of "the window" (its NSWindow for a dialog, whether it is
// active, its bounds) is answered with the OpenArch window its pages are
// shown in. Nothing of Chrome's own window can show, take the focus or be
// closed by the user.

#ifndef OPENARCH_PAGE_WINDOW_H_
#define OPENARCH_PAGE_WINDOW_H_

class BrowserWindow;
class BrowserWindowInterface;

namespace openarch {

// Makes the window for |browser|, owned by Chrome (BrowserWindowDeleter).
BrowserWindow* MakePageWindow(BrowserWindowInterface* browser);

}  // namespace openarch

#endif  // OPENARCH_PAGE_WINDOW_H_
