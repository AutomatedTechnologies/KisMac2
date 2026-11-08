//
//  NUManageViewController.h
//  Network Utility (Switchboard V1) — Manage (READ) panel UI.
//
//  Station list (Bonjour _airport._tcp + manual add-by-IP), one read button,
//  sectioned configuration display plus a raw property table with password
//  values excluded by the client layer. READ ONLY: there is no control in
//  this UI that can change a base station, and no write path behind it.
//  Classroom mode (NSUserDefaults key "NUClassroomMode", owned by the
//  shell): no credential prompt is ever shown.
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Cocoa/Cocoa.h>
#import "NUTarget.h"

NS_ASSUME_NONNULL_BEGIN

@interface NUManageViewController : NSViewController
// Fired when the user selects a station, so the shell can aim the shared
// current target (spec §5.2). The target is nil when nothing is selected
// or the station has no resolved address.
@property (nonatomic, copy, nullable) void (^onSelectTarget)(NUTarget * _Nullable target);
// Supplies the current Discover survey to the Optimizations audit
// (Switchboard files/08 §2/§4), as plain records in the shape
// NUOptimizationEngine consumes: @{@"ssid": NSString, @"channel": NSNumber,
// @"signal": NSNumber}. Set by the shell, which hosts the scanner. May
// return nil when no survey is available — the engine then stays silent
// on its scan-dependent checks, by its own honesty rules; it never
// evaluates against a stored or assumed picture of the neighborhood.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> * _Nullable (^scanNetworksProvider)(void);
@end

NS_ASSUME_NONNULL_END
