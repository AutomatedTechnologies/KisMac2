//
//  NUShellController.h
//  Network Utility (Switchboard V1) — unified shell.
//
//  One window: sidebar (Networks / Base Stations / Diagnostics sections,
//  Journal at the foot), the selected section's content, and an
//  always-visible status bar — KisMac 07-V2-UNIFIED-SPEC.md §5, built to
//  the Academy Software Design Standards (monochrome, system font, states
//  in words). The existing KisMac scan UI is hosted, unmodified, as the
//  Networks content (V2-T2: the shell lands on the V1 tree; Discover
//  behavior frozen — no engine file changes).
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Cocoa/Cocoa.h>
#import "NUTarget.h"

NS_ASSUME_NONNULL_BEGIN

@interface NUShellController : NSObject
+ (instancetype)sharedController;
// The shell's shared current target (spec §5.2). Set by Manage when a base
// station is selected; aims Diagnose. Status bar shows its validated form.
@property (nonatomic, strong, nullable) NUTarget *currentTarget;
@end

NS_ASSUME_NONNULL_END
