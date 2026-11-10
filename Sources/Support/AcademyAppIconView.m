//
//  AcademyAppIconView.m
//  Detroit Automation Academy — shared SDS-8 / SDS-10 component
//  (KisMac shell lineage: KisMac and Workbench; SDS10-T1, 2026-11-10)
//

#import "AcademyAppIconView.h"

static const NSTimeInterval AcademyAppIconPulsePeriod = 2.0;

@interface AcademyAppIconView ()
@property (nonatomic, strong) NSTimer *pulseTimer;
@property (nonatomic) NSTimeInterval pulseStart;
@end

@implementation AcademyAppIconView

- (BOOL)isOpaque {
    return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    NSImage *icon = [NSApp applicationIconImage];
    if (icon == nil) return;

    // Aspect-fit the AppIcon composition inside the view's bounds.
    NSSize iconSize = [icon size];
    if (iconSize.width <= 0 || iconSize.height <= 0) return;
    NSRect bounds = [self bounds];
    CGFloat scale = MIN(NSWidth(bounds) / iconSize.width,
                        NSHeight(bounds) / iconSize.height);
    NSSize drawnSize = NSMakeSize(iconSize.width * scale, iconSize.height * scale);
    NSRect drawnRect = NSMakeRect(NSMidX(bounds) - drawnSize.width / 2,
                                  NSMidY(bounds) - drawnSize.height / 2,
                                  drawnSize.width, drawnSize.height);

    // SDS-8 pulse: opacity breathes over the 2 s period while the
    // welcome is up and motion is allowed; full opacity otherwise.
    CGFloat fraction = 1.0;
    if (self.pulseTimer != nil) {
        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.pulseStart;
        CGFloat phase = (CGFloat)fmod(elapsed / AcademyAppIconPulsePeriod, 1.0);
        fraction = 0.86 + 0.14 * (0.5 + 0.5 * cos(phase * 2.0 * M_PI));
    }
    [icon drawInRect:drawnRect
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:fraction];
}

#pragma mark - Animation lifecycle (DistroLogoView pattern)

- (BOOL)motionAllowed {
    return ![[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion];
}

- (BOOL)windowVisibleAndUnoccluded {
    NSWindow *w = [self window];
    if (w == nil || ![w isVisible]) return NO;
    return ([w occlusionState] & NSWindowOcclusionStateVisible) != 0;
}

- (void)refreshAnimationState {
    if ([self motionAllowed] && [self windowVisibleAndUnoccluded]) {
        if (self.pulseTimer == nil) {
            self.pulseStart = [NSDate timeIntervalSinceReferenceDate];
            self.pulseTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0
                                                                 target:self
                                                               selector:@selector(tick:)
                                                               userInfo:nil
                                                                repeats:YES];
        }
    } else {
        [self stopAnimation];
    }
    [self setNeedsDisplay:YES];
}

- (void)stopAnimation {
    [self.pulseTimer invalidate];
    self.pulseTimer = nil;
}

- (void)tick:(NSTimer *)timer {
    if (![self windowVisibleAndUnoccluded] || ![self motionAllowed]) {
        [self refreshAnimationState];
        return;
    }
    [self setNeedsDisplay:YES];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidChangeOcclusionStateNotification
                                                  object:nil];
    if ([self window] != nil) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(refreshAnimationState)
                                                     name:NSWindowDidChangeOcclusionStateNotification
                                                   object:[self window]];
    }
    [self refreshAnimationState];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    if (newWindow == nil) [self stopAnimation];
}

- (void)dealloc {
    [self stopAnimation];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
