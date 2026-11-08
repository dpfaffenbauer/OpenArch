// The Dock's plug-in for OpenArch: while OpenArch is not running, the Dock
// shows the app icon chosen in Settings › Allgemein instead of the bundle's
// own. OpenArch keeps that icon as DockIcon.png in its Application Support
// folder, so the app bundle stays exactly as it was signed. For „Jeden Tag“
// it keeps every design in DockIcons/<n>.png instead, and the plug-in picks
// the day's own, a new one when the day changes. Built into
// Contents/PlugIns by App/build.sh.

#import <AppKit/AppKit.h>

@interface OpenArchDockTile : NSObject <NSDockTilePlugIn>
@property(nonatomic, strong, nullable) NSDockTile* tile;
@property(nonatomic, strong, nullable) id observer;
@property(nonatomic, strong, nullable) id dayObserver;
@end

@implementation OpenArchDockTile

- (void)setDockTile:(NSDockTile*)dockTile {
  if (self.observer) {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self.observer];
    self.observer = nil;
  }
  if (self.dayObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:self.dayObserver];
    self.dayObserver = nil;
  }
  self.tile = dockTile;
  if (!dockTile) {
    return;
  }
  [self update];
  // OpenArch says so when it changes the icon.
  __weak OpenArchDockTile* weakSelf = self;
  self.observer = [NSDistributedNotificationCenter.defaultCenter
      addObserverForName:@"dev.openarch.dockIconChanged"
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* notification) {
                [weakSelf update];
              }];
  // „Jeden Tag“: the next design at midnight.
  self.dayObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSCalendarDayChangedNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* notification) {
                [weakSelf update];
              }];
}

- (void)update {
  NSString* support =
      [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/OpenArch"];
  NSImage* image = nil;
  // Counted as AppIcons.design(for:) counts: the day in the era, modulo
  // the number of designs.
  NSString* daily = [support stringByAppendingPathComponent:@"DockIcons"];
  NSArray<NSString*>* files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:daily error:nil]
      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.png'"]];
  if (files.count > 0) {
    NSInteger day = [NSCalendar.currentCalendar ordinalityOfUnit:NSCalendarUnitDay
                                                          inUnit:NSCalendarUnitEra
                                                         forDate:[NSDate date]];
    NSString* name = [NSString stringWithFormat:@"%ld.png", (long)(day % (NSInteger)files.count)];
    image = [[NSImage alloc] initWithContentsOfFile:[daily stringByAppendingPathComponent:name]];
  }
  if (!image) {
    image = [[NSImage alloc] initWithContentsOfFile:[support stringByAppendingPathComponent:@"DockIcon.png"]];
  }
  if (image) {
    NSImageView* view = [NSImageView imageViewWithImage:image];
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.tile.contentView = view;
  } else {
    self.tile.contentView = nil;
  }
  [self.tile display];
}

@end
