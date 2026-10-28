// The Dock's plug-in for OpenArch: while OpenArch is not running, the Dock
// shows the app icon chosen in Settings › Allgemein instead of the bundle's
// own. OpenArch keeps that icon as DockIcon.png in its Application Support
// folder, so the app bundle stays exactly as it was signed. Built into
// Contents/PlugIns by App/build.sh.

#import <AppKit/AppKit.h>

@interface OpenArchDockTile : NSObject <NSDockTilePlugIn>
@property(nonatomic, strong, nullable) NSDockTile* tile;
@property(nonatomic, strong, nullable) id observer;
@end

@implementation OpenArchDockTile

- (void)setDockTile:(NSDockTile*)dockTile {
  if (self.observer) {
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self.observer];
    self.observer = nil;
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
}

- (void)update {
  NSString* path = [NSHomeDirectory()
      stringByAppendingPathComponent:@"Library/Application Support/OpenArch/DockIcon.png"];
  NSImage* image = [[NSImage alloc] initWithContentsOfFile:path];
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
