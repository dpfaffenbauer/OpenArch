// Adapted from Ardia (https://github.com/ardia-browser/ardia,
// packages/ardiacore/ios/ArdiaProtectedVideo.mm), Apache License 2.0,
// Copyright 2026 Mantra Patel. Changed for OpenArch. See NOTICE.

#import "Internal.h"

using namespace oa_protected_video;

static BOOL gTraces = NO;

@implementation OAProtectedVideo

// One session per page, gone with the page.
+ (NSMapTable<id<OAPVPage>, OAPVSession *> *)sessions {
  static NSMapTable *sessions = [NSMapTable weakToStrongObjectsMapTable];
  return sessions;
}

+ (BOOL)traces {
  return gTraces;
}

+ (void)setTraces:(BOOL)traces {
  gTraces = traces;
}

+ (void)page:(id<OAPVPage>)page message:(NSDictionary *)message {
  if (!page || page.isClosed) return;
  OAPVSession *session = [self.sessions objectForKey:page];
  if (!session) {
    session = [[OAPVSession alloc] initWithPage:page];
    [self.sessions setObject:session forKey:page];
  }
  [session handle:message];
}

+ (void)pageGone:(id<OAPVPage>)page {
  if (!page) return;
  OAPVSession *session = [self.sessions objectForKey:page];
  if (!session) return;
  [self.sessions removeObjectForKey:page];
  [session close];
}

+ (void)muteChanged:(id<OAPVPage>)page {
  if (page) [[self.sessions objectForKey:page] muteChanged];
}

+ (BOOL)isActive:(id<OAPVPage>)page {
  return page && [[self.sessions objectForKey:page] active];
}

+ (BOOL)plays:(id<OAPVPage>)page {
  return page && [[self.sessions objectForKey:page] plays];
}

+ (NSInteger)shownFrames:(id<OAPVPage>)page {
  return page ? [[self.sessions objectForKey:page] shownFrames] : 0;
}

+ (BOOL)startPictureInPicture:(id<OAPVPage>)page {
  return [[self.sessions objectForKey:page] startPictureInPicture];
}

+ (void)exitPictureInPicture:(id<OAPVPage>)page {
  if (page) [[self.sessions objectForKey:page] exitPictureInPicture];
}

@end
