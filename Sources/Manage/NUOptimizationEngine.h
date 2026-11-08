//
//  NUOptimizationEngine.h
//  Workbench (Switchboard V1) — Optimizations: read-only configuration audit.
//
//  Design: Switchboard files/08-OPTIMIZATIONS-DESIGN.md (2026-11-07).
//
//  The engine consumes two inputs the app already holds — the base
//  station's configuration snapshot (the ACP property payload from the
//  same authenticated read session NUAirPortClient performs; the session
//  password is memory-only and never reaches this module) and the live
//  Discover scan — and produces a graded findings list: current value,
//  recommended value, one plain-language line of why.
//
//  READ ONLY BY CONSTRUCTION. This module performs no I/O, opens no
//  connection, and contains no code path that can change a station: it
//  evaluates and recommends, nothing else. Applying any recommendation
//  is Manage WRITE — the gated post-MVP tranche (Switchboard
//  files/05-MANAGE-WRITE-SECURITY.md, three locks) — and is out of scope
//  here and in the panel that will present these findings.
//
//  Honesty rules (design doc §2):
//  - A check whose inputs are absent produces NO finding. The engine
//    never guesses a current value, and never recommends against data it
//    did not see.
//  - Congestion claims come only from the scan passed in, never from a
//    stored or assumed RF picture.
//  - Device-controlled strings (SSIDs, client names, disk names) are
//    sanitized through TargetKit before they enter a finding.
//
//  Input shapes (plain data, transport-free):
//  - properties: the ACP property dictionary (as in NUAirPortClient).
//  - scanNetworks: array of dictionaries, one per observed network:
//      @"ssid"    NSString (may be empty for hidden networks)
//      @"channel" NSNumber
//      @"signal"  NSNumber — received strength; higher is stronger
//                 (dBm or the Discover engine's normalized scale; only
//                 relative comparisons are made, so either serves)
//  - clients: array of dictionaries, one per associated client the read
//    supplied (optional; may be nil):
//      @"name"        NSString
//      @"stationary"  NSNumber BOOL — always-associated class
//      @"highTraffic" NSNumber BOOL
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NUOptimizationSeverity) {
    // A clear better value exists for a setting as it stands.
    NUOptimizationSeverityRecommendation = 0,
    // Worth attention; the better value depends on circumstance.
    NUOptimizationSeverityAdvisory       = 1,
    // No change recommended; load/context the operator should know.
    NUOptimizationSeverityInformational  = 2,
};

@interface NUOptimizationFinding : NSObject
@property (nonatomic, copy, readonly) NSString *checkID;        // stable id, e.g. @"channel-2.4"
@property (nonatomic, copy, readonly) NSString *title;          // plain language, SDS-2
@property (nonatomic, copy, readonly) NSString *currentValue;
@property (nonatomic, copy, readonly) NSString *recommendedValue;
@property (nonatomic, copy, readonly) NSString *rationale;      // one line, plain language
@property (nonatomic, readonly) NUOptimizationSeverity severity;
- (instancetype)initWithCheckID:(NSString *)checkID
                          title:(NSString *)title
                   currentValue:(NSString *)currentValue
              recommendedValue:(NSString *)recommendedValue
                      rationale:(NSString *)rationale
                       severity:(NUOptimizationSeverity)severity;
@end

@interface NUOptimizationEngine : NSObject
// Evaluate all checks whose inputs are present. Findings are returned
// ordered by severity (recommendations first), then by check order.
// Returns an empty array when no check has the data it needs.
+ (NSArray<NUOptimizationFinding *> *)findingsFromProperties:(NSDictionary *)properties
                                                scanNetworks:(NSArray<NSDictionary *> *)scanNetworks
                                                     clients:(nullable NSArray<NSDictionary *> *)clients;
// Panel rows: one row per finding — item is the title, value is
// "Current → Recommended — why" in one display string.
+ (NSArray<NSDictionary *> *)rowsFromFindings:(NSArray<NUOptimizationFinding *> *)findings;
// One journal record body (Diagnose record family): a line per finding.
+ (NSString *)journalSummaryFromFindings:(NSArray<NUOptimizationFinding *> *)findings;
@end

NS_ASSUME_NONNULL_END
