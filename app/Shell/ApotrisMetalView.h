#pragma once
// CAMetalLayer-backed host view: presents the game's 512x512 framebuffer with
// upstream's scale/crop math and paces the game thread from its display link.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ApotrisMetalView : UIView

- (void)setPaused:(BOOL)paused;      // pause/resume the display link
- (void)setFilterMode:(NSInteger)mode; // 0 sharp, 1 lcd, 2 crt

@end

NS_ASSUME_NONNULL_END
