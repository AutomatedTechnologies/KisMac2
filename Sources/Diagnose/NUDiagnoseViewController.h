//
//  NUDiagnoseViewController.h
//  Network Utility (Switchboard V1) — Diagnose panels UI.
//
//  One content view hosting the four MVP panels (Ping, Netstat, Traceroute,
//  Speed Test) behind a panel selector, per the Switchboard 03-V1-MVP.md
//  scope and the 02-DIAGNOSE-DESIGN.md contracts. Every target passes
//  TargetKit before any socket opens; every run is journaled with the
//  validated target form only. No shell, no privilege (engines' law).
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Cocoa/Cocoa.h>
#import "NUTarget.h"

NS_ASSUME_NONNULL_BEGIN

@interface NUDiagnoseViewController : NSViewController
// Pre-aims the target field from the shell's shared current target
// (spec §5.2). Setting it never starts a run by itself.
@property (nonatomic, strong, nullable) NUTarget *currentTarget;
@end

NS_ASSUME_NONNULL_END
