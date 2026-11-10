//
//  AcademyWelcomeController.m
//  Detroit Automation Academy — shared SDS-8 / SDS-10 component
//  (KisMac shell lineage: KisMac and Workbench; SDS10-T1, 2026-11-10)
//

#import "AcademyWelcomeController.h"
#import "AcademyAppIconView.h"

static NSTextField *AcademyWelcomeLabel(NSString *text, CGFloat size, BOOL bold, NSColor *color) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    [label setStringValue:text];
    [label setFont:bold ? [NSFont boldSystemFontOfSize:size]
                        : [NSFont systemFontOfSize:size]];
    [label setTextColor:color];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setAlignment:NSTextAlignmentCenter];
    return label;
}

// The version line (SDS-10 10.2): composed at presentation time from
// the hosting bundle's own Info.plist — CFBundleShortVersionString
// and CFBundleVersion, both read at runtime, never hardcoded. In the
// shipped catalog builds CFBundleVersion is the catalog build tag
// (stamped by CI), so the welcome states exactly the build it is.
static NSString *AcademyWelcomeVersionLine(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *build = [info objectForKey:@"CFBundleVersion"];
    NSString *shortVersion = [info objectForKey:@"CFBundleShortVersionString"];
    if (build != nil && shortVersion != nil &&
        ![build isEqualToString:shortVersion]) {
        return [NSString stringWithFormat:@"Version %@ (%@)", shortVersion, build];
    }
    if (build != nil) return [NSString stringWithFormat:@"Version %@", build];
    if (shortVersion != nil) return [NSString stringWithFormat:@"Version %@", shortVersion];
    return @"";
}

static NSString *AcademyWelcomeAppName(void) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *name = [info objectForKey:@"CFBundleDisplayName"];
    if (name == nil) name = [info objectForKey:@"CFBundleName"];
    if (name == nil) name = [[NSProcessInfo processInfo] processName];
    return name;
}

@interface AcademyWelcomeController ()
@property (nonatomic, strong) NSSound *startupSound;
@property (nonatomic) BOOL soundPlayed;
@end

@implementation AcademyWelcomeController

static AcademyWelcomeController *AcademyWelcomeSharedController = nil;

+ (void)presentWelcome {
    if (AcademyWelcomeSharedController == nil) {
        AcademyWelcomeSharedController = [[AcademyWelcomeController alloc] init];
    }
    [AcademyWelcomeSharedController showWindow:nil];
    [[AcademyWelcomeSharedController window] makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (id)init {
    NSRect frame = NSMakeRect(0, 0, 480, 460);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
          backing:NSBackingStoreBuffered
            defer:NO];
    [window setTitle:[NSString stringWithFormat:@"Welcome to %@", AcademyWelcomeAppName()]];
    [window setReleasedWhenClosed:NO];
    self = [super initWithWindow:window];
    if (self) {
        NSView *content = [window contentView];
        CGFloat w = NSWidth(frame);
        CGFloat top = NSHeight(frame);

        // The AppIcon composition, drawn by the single shared view
        // (SDS-10 10.1.2 — `AcademyAppIconView`, the lineage's
        // counterpart of Distro's `DistroLogoView`).
        AcademyAppIconView *iconView = [[AcademyAppIconView alloc]
            initWithFrame:NSMakeRect((w - 132) / 2, top - 48 - 132, 132, 132)];
        [content addSubview:iconView];

        NSTextField *name = AcademyWelcomeLabel(AcademyWelcomeAppName(), 28, YES,
                                                [NSColor blackColor]);
        [name setFrame:NSMakeRect(40, NSMinY([iconView frame]) - 52, w - 80, 36)];
        [content addSubview:name];

        NSTextField *signature = AcademyWelcomeLabel(@"Detroit Automation Academy", 13, NO,
            [NSColor colorWithCalibratedWhite:0.27 alpha:1.0]);
        [signature setFrame:NSMakeRect(40, NSMinY([name frame]) - 28, w - 80, 20)];
        [content addSubview:signature];

        NSTextField *copyLine = AcademyWelcomeLabel(
            @"Maintained by the Detroit Automation Academy for macOS "
            @"High Sierra — disassembled, scanned, and recompiled "
            @"through the Academy pipeline.", 12.5, NO, [NSColor blackColor]);
        [copyLine setFrame:NSMakeRect(50, NSMinY([signature frame]) - 66, w - 100, 54)];
        [[copyLine cell] setWraps:YES];
        [content addSubview:copyLine];

        NSButton *continueButton = [[NSButton alloc]
            initWithFrame:NSMakeRect((w - 140) / 2, 48, 140, 32)];
        [continueButton setTitle:@"Continue"];
        [continueButton setBezelStyle:NSBezelStyleRounded];
        [continueButton setFont:[NSFont systemFontOfSize:13]];
        [continueButton setTarget:self];
        [continueButton setAction:@selector(continuePressed:)];
        [continueButton setKeyEquivalent:@"\r"];
        // Monochrome standard (DAADV2/SDS): a window default button
        // renders blue (pulsing) on 10.13, so Continue is NOT set as
        // the window's default button cell — the Return key
        // equivalent above still dismisses (the `DistroWelcomeController`
        // pattern).
        [content addSubview:continueButton];

        // Version at startup (SDS-10 10.2.1), at the foot of the
        // welcome screen — runtime-read above, never hardcoded.
        NSTextField *version = AcademyWelcomeLabel(AcademyWelcomeVersionLine(), 11, NO,
            [NSColor colorWithCalibratedWhite:0.27 alpha:1.0]);
        [version setFrame:NSMakeRect(40, 14, w - 80, 16)];
        [content addSubview:version];

        [window center];
    }
    return self;
}

// The standard startup sound (SDS-10 10.3.1: the library master,
// design-v2/startup-sound.wav, byte-identical in this bundle's
// Resources) plays ONCE when the welcome screen presents — system
// volume, no loop, no replay on Continue. A missing file proceeds
// silently; there is no error surface for it (the catalog gate
// checks the bundled asset's hash at package time).
- (void)playStartupSoundOnce {
    if (self.soundPlayed) return;
    self.soundPlayed = YES;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"startup-sound"
                                                     ofType:@"wav"];
    if (path == nil) return;
    self.startupSound = [[NSSound alloc] initWithContentsOfFile:path byReference:NO];
    [self.startupSound play];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self playStartupSoundOnce];
}

- (void)continuePressed:(id)sender {
    [[self window] close];
}

// Escape dismisses, exactly like Continue (SDS-8: user-driven dismissal).
- (void)cancelOperation:(id)sender {
    [self continuePressed:sender];
}

@end
