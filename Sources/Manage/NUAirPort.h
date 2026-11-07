//
//  NUAirPort.h
//  Network Utility (Switchboard V1) — Manage (READ) for AirPort base stations.
//
//  Discovery: Bonjour _airport._tcp. Configuration read: the AirPort admin
//  protocol on TCP/5009, property model per the public ACP references
//  (4-character property codes with typed values; nested "WiFi" property
//  list). Properties of interest:
//    syNm name · syAP product · syVs firmware · syDs description · sySN serial
//    WiFi.raNm SSID · bsSM security · bsRC channel · bsRM connection sharing
//    waIP/waSM/waRA/waD1..3 WAN · MaSt disks (Time Capsule) · bsFS file sharing
//  The password property (syPW) and any password-typed value are NEVER
//  displayed, journaled, or included in the raw property table.
//
//  READ ONLY: this module contains no configuration write path — no setprop,
//  no apply, no reboot. Verify with:
//    grep -nEi 'setprop|write|reboot|apply' Sources/Manage/*.m
//  (the only matches are this statement and socket-level byte plumbing in
//  the transport section, which sends exactly one read request).
//
//  The session password is held in memory for the duration of one fetch and
//  nowhere else: not stored, not logged, not journaled (MVP spec §3, design
//  TargetKit logging rules).
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class NUTarget;

@interface NUAirPortStation : NSObject
@property (nonatomic, copy, readonly) NSString *displayName;   // Bonjour name or IP
@property (nonatomic, copy, readonly, nullable) NSString *ipAddress; // IPv4 literal once resolved
@property (nonatomic, copy, readonly) NSDictionary *txtRecord;
@property (nonatomic, copy, readonly) NSString *modelHint;
- (instancetype)initWithDisplayName:(NSString *)name
                         ipAddress:(nullable NSString *)ip
                         txtRecord:(NSDictionary *)txt;
@end

// Completion delivers a sections array for the panel UI:
//   @{ @"title": NSString, @"rows": @[ @{@"item":…, @"value":…}, … ] }
// plus the raw property table (password values excluded).
typedef void (^NUAirPortFetchCompletion)(NSArray<NSDictionary *> * _Nullable sections,
                                         NSDictionary * _Nullable rawProperties,
                                         NSString * _Nullable error);

@interface NUAirPortClient : NSObject
// One read session: connect → authenticate (if a password is given) →
// request the full property set → structured parse. Runs on a background
// queue; completion on the main queue.
//
// TRANSPORT NOTE (honest scope): the ACP wire framing lives in this one
// class and follows the public protocol references; byte-accuracy against
// a real base station is verified in the P2 rig tranche against the house
// AirPort Extreme. If the station's answer cannot be parsed as a property
// payload, the completion reports that plainly instead of guessing.
+ (void)fetchConfigurationForStation:(NUAirPortStation *)station
                            password:(nullable NSString *)password
                          completion:(NUAirPortFetchCompletion)completion;
// View-model construction, separated from the transport so it is testable
// against any captured property payload.
+ (NSArray<NSDictionary *> *)sectionsFromProperties:(NSDictionary *)properties;
+ (NSDictionary *)displayableRawProperties:(NSDictionary *)properties;
@end

@interface NUAirPortBrowser : NSObject
@property (nonatomic, copy, readonly) NSArray<NUAirPortStation *> *stations;
@property (nonatomic, copy, nullable) dispatch_block_t onChange;
- (void)startBrowsing;
- (void)stopBrowsing;
- (void)addStationWithTarget:(NUTarget *)target; // manual add by IP literal
@end

NS_ASSUME_NONNULL_END
