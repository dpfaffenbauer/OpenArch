#import "openarch/findbar.h"

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "components/find_in_page/find_notification_details.h"
#include "components/find_in_page/find_result_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "content/public/browser/web_contents.h"

@interface OAFindBar () <NSSearchFieldDelegate>
- (void)resultsChanged;
@end

namespace {

constexpr CGFloat kWidth = 320;
constexpr CGFloat kHeight = 36;
constexpr CGFloat kMargin = 10;

// Chrome's find results, to the bar.
class FindResults : public find_in_page::FindResultObserver {
 public:
  FindResults(find_in_page::FindTabHelper* helper, OAFindBar* bar) : bar_(bar) {
    observation_.Observe(helper);
  }
  void OnFindResultAvailable(content::WebContents*) override { [bar_ resultsChanged]; }

 private:
  __weak OAFindBar* bar_;
  base::ScopedObservation<find_in_page::FindTabHelper, find_in_page::FindResultObserver>
      observation_{this};
};

}  // namespace

@implementation OAFindBar {
  raw_ptr<content::WebContents> _contents;
  std::unique_ptr<FindResults> _results;
  NSSearchField* _field;
  NSTextField* _count;
}

- (instancetype)initWithWebContents:(content::WebContents*)contents {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, kWidth, kHeight)])) {
    _contents = contents;
    find_in_page::FindTabHelper::CreateForWebContents(contents);
    _results = std::make_unique<FindResults>(
        find_in_page::FindTabHelper::FromWebContents(contents), self);

    self.material = NSVisualEffectMaterialPopover;
    self.blendingMode = NSVisualEffectBlendingModeWithinWindow;
    self.state = NSVisualEffectStateActive;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8;
    self.layer.masksToBounds = YES;

    _field = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 6, 170, 24)];
    _field.placeholderString = @"Auf der Seite suchen";
    _field.delegate = self;
    _field.sendsSearchStringImmediately = YES;
    [self addSubview:_field];

    _count = [NSTextField labelWithString:@""];
    _count.frame = NSMakeRect(184, 9, 54, 18);
    _count.alignment = NSTextAlignmentRight;
    _count.textColor = NSColor.secondaryLabelColor;
    _count.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    [self addSubview:_count];

    struct {
      NSString* symbol;
      NSString* tip;
      SEL action;
      CGFloat x;
    } buttons[] = {
        {@"chevron.up", @"Vorheriger Treffer", @selector(previous:), 242},
        {@"chevron.down", @"Nächster Treffer", @selector(next:), 266},
        {@"xmark", @"Schließen", @selector(closeBar:), 292},
    };
    for (const auto& item : buttons) {
      NSButton* button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:item.symbol
                                                             accessibilityDescription:item.tip]
                                            target:self
                                            action:item.action];
      button.bordered = NO;
      button.toolTip = item.tip;
      button.frame = NSMakeRect(item.x, 7, 22, 22);
      [self addSubview:button];
    }
  }
  return self;
}

- (BOOL)isOpen {
  return self.superview != nil;
}

- (void)showInView:(NSView*)view pageFrame:(NSRect)pageFrame {
  if (self.superview != view) {
    [self removeFromSuperview];
    [view addSubview:self positioned:NSWindowAbove relativeTo:nil];
  }
  [self placeInPageFrame:pageFrame];
  // Chrome's find bar starts with the last search on the page.
  if (_contents && !_field.stringValue.length) {
    auto* helper = find_in_page::FindTabHelper::FromWebContents(_contents);
    _field.stringValue = base::SysUTF16ToNSString(helper->previous_find_text());
  }
  [self.window makeFirstResponder:_field];
  [_field selectText:nil];
  if (_field.stringValue.length) {
    [self search:YES];
  }
}

- (void)placeInPageFrame:(NSRect)pageFrame {
  BOOL flipped = self.superview.isFlipped;
  CGFloat y = flipped ? NSMinY(pageFrame) + kMargin : NSMaxY(pageFrame) - kMargin - kHeight;
  self.frame = NSMakeRect(NSMaxX(pageFrame) - kMargin - kWidth, y, kWidth, kHeight);
}

- (void)findNext:(BOOL)forward {
  if (!_field.stringValue.length) {
    return;
  }
  [self search:forward];
}

- (void)search:(BOOL)forward {
  if (!_contents) {
    return;
  }
  auto* helper = find_in_page::FindTabHelper::FromWebContents(_contents);
  NSString* text = _field.stringValue;
  if (!text.length) {
    helper->StopFinding(find_in_page::SelectionAction::kClear);
    _count.stringValue = @"";
    return;
  }
  helper->StartFinding(base::SysNSStringToUTF16(text), forward, /*case_sensitive=*/false,
                       /*find_match=*/true);
}

- (void)resultsChanged {
  if (!_contents) {
    return;
  }
  const auto& result = find_in_page::FindTabHelper::FromWebContents(_contents)->find_result();
  if (!_field.stringValue.length) {
    _count.stringValue = @"";
  } else if (result.number_of_matches() <= 0) {
    _count.stringValue = @"0/0";
  } else {
    _count.stringValue = [NSString stringWithFormat:@"%d/%d", MAX(result.active_match_ordinal(), 0),
                                                    result.number_of_matches()];
  }
}

- (void)close {
  if (_contents) {
    find_in_page::FindTabHelper::FromWebContents(_contents)->StopFinding(
        find_in_page::SelectionAction::kKeep);
  }
  _count.stringValue = @"";
  BOOL hadFocus = self.window.firstResponder == _field.currentEditor;
  NSWindow* window = self.window;
  [self removeFromSuperview];
  if (hadFocus && _contents) {
    [window makeFirstResponder:_contents->GetNativeView().GetNativeNSView()];
    _contents->Focus();
  }
}

- (void)detachWebContents {
  _results.reset();
  _contents = nullptr;
  [self removeFromSuperview];
}

#pragma mark Controls

- (void)controlTextDidChange:(NSNotification*)notification {
  [self search:YES];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
  if (command == @selector(insertNewline:)) {
    BOOL backwards = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
    [self search:!backwards];
    return YES;
  }
  if (command == @selector(cancelOperation:)) {
    [self close];
    return YES;
  }
  return NO;
}

- (void)previous:(id)sender {
  [self findNext:NO];
}

- (void)next:(id)sender {
  [self findNext:YES];
}

- (void)closeBar:(id)sender {
  [self close];
}

@end
