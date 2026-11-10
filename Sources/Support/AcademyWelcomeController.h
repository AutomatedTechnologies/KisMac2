//
//  AcademyWelcomeController.h
//  Detroit Automation Academy — shared SDS-8 / SDS-10 component
//  (KisMac shell lineage: KisMac and Workbench; SDS10-T1, 2026-11-10)
//
//  The standard animated-logo welcome screen (SDS-8), shared by the
//  KisMac shell lineage: presented at launch before the app's main
//  work begins — the app's AppIcon composition drawn by the single
//  view `AcademyAppIconView` (SDS-10 10.1.2), the app name, the
//  Detroit Automation Academy signature line, one line of
//  verified-state copy, the build's version displayed at the foot
//  of the screen and read from the bundle's own `Info.plist` at
//  runtime (SDS-10 10.2.2 — never hardcoded), and a single
//  user-driven Continue action (button; Return and Escape also
//  dismiss). The standard startup sound (SDS-10 10.3) plays once
//  when the screen presents. No auto-dismiss timer, no blocking
//  delay.
//
//  This file is byte-identical in every app of the lineage that
//  carries the shared welcome component. Do not fork it per app.
//
//  macOS 10.13 floor. Objective-C, ARC.
//

#import <Cocoa/Cocoa.h>

@interface AcademyWelcomeController : NSWindowController

// Present the shared welcome screen (once per launch). Called by the
// hosting app from its applicationDidFinishLaunching path.
+ (void)presentWelcome;

@end
