//
//  AcademyAppIconView.h
//  Detroit Automation Academy — shared SDS-8 / SDS-10 component
//  (KisMac shell lineage: KisMac and Workbench; SDS10-T1, 2026-11-10)
//
//  The single view that draws the hosting app's AppIcon composition
//  (SDS-10 clause 10.1.2 — the conforming pattern is a single view
//  that draws the AppIcon composition, as `DistroLogoView` does in
//  Distro from distro-test-40). This view draws the bundle's own
//  application icon image — the same master the bundle `AppIcon`,
//  the Dock, and the Distro catalog artwork are rendered from — so
//  the composition cannot diverge by surface. The SDS-8 signal-arc
//  pulse is expressed as a gentle opacity pulse of the icon itself;
//  the mark is static under Reduce Motion.
//
//  This file is byte-identical in every app of the lineage that
//  carries the shared welcome component. Do not fork it per app.
//
//  macOS 10.13 floor. Objective-C, ARC (the lineage target builds
//  with CLANG_ENABLE_OBJC_ARC = YES).
//

#import <Cocoa/Cocoa.h>

@interface AcademyAppIconView : NSView

@end
