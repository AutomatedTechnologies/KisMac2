//
//  NUDiagnoseEngines.h
//  Network Utility (Switchboard V1) — Diagnose engines.
//
//  Built exactly to Switchboard 02-DIAGNOSE-DESIGN.md: no shell anywhere
//  (no NSTask/posix_spawn/system exists in this module), no privilege, all
//  targets arrive pre-validated as NUTarget (TargetKit), all engines are
//  cancellable and bounded. Engines report through blocks on the main queue
//  unless a different callback queue is set.
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>
#import "NUTarget.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Ping

typedef void (^NUPingReplyBlock)(uint16_t sequence, double rttMilliseconds);
typedef void (^NUPingCompletionBlock)(NSDictionary *stats, NSString * _Nullable error);
// stats keys: sent, received, lossPercent, minMs, avgMs, maxMs (NSNumber)

@interface NUPingEngine : NSObject
@property (nonatomic, strong, readonly) NUTarget *target;
@property (nonatomic, readonly) NSInteger count;    // 1..100 (design §2)
@property (nonatomic, readonly) NSTimeInterval interval; // >= 0.2 s
@property (nonatomic, copy, nullable) NUPingReplyBlock onReply;
@property (nonatomic, copy, nullable) NUPingCompletionBlock onCompletion;
- (instancetype)initWithTarget:(NUTarget *)target count:(NSInteger)count interval:(NSTimeInterval)interval;
- (void)start;
- (void)cancel;
@end

#pragma mark - Traceroute

typedef void (^NUTracerouteHopBlock)(NSInteger hop, NSString * _Nullable responderIP,
                                     NSArray<NSNumber *> *rttMilliseconds, BOOL reachedTarget);
typedef void (^NUTracerouteCompletionBlock)(NSString * _Nullable error);

@interface NUTracerouteEngine : NSObject
@property (nonatomic, strong, readonly) NUTarget *target;
@property (nonatomic, readonly) NSInteger maxHops;          // 1..64 (design §4)
@property (nonatomic, readonly) NSTimeInterval probeTimeout; // 1..5 s
@property (nonatomic, copy, nullable) NUTracerouteHopBlock onHop;
@property (nonatomic, copy, nullable) NUTracerouteCompletionBlock onCompletion;
- (instancetype)initWithTarget:(NUTarget *)target maxHops:(NSInteger)maxHops probeTimeout:(NSTimeInterval)probeTimeout;
- (void)start;
- (void)cancel;
@end

#pragma mark - Netstat (local machine state; design §8)

// Formatted, display-ready snapshots of the kernel's own tables, parsed
// in-process: routes via sysctl NET_RT_DUMP, interfaces via getifaddrs,
// sockets via libproc proc_pidfdinfo. No netstat binary, no privilege.
@interface NUNetstat : NSObject
+ (NSString *)routingTableText;
+ (NSString *)interfaceTableText;
+ (NSString *)socketTableText;
// Structured default-route facts for the Speed Test gateway leg.
+ (nullable NSDictionary *)defaultRouteInfo; // keys: gatewayIP, interface, family
+ (uint64_t)negotiatedBaudRateForInterface:(NSString *)interfaceName; // 0 = unknown
@end

#pragma mark - Speed Test (gateway + LAN legs only; design §9, MVP scope)

typedef void (^NUSpeedCompletionBlock)(NSString *summary, NSString * _Nullable error);

// Gateway leg: latency/loss from the Ping engine against the default
// gateway + the negotiated link rate of the route's interface. No gateway
// "throughput" number is ever fabricated — there is no cooperating endpoint.
// LAN leg: latency/loss to a user-chosen LAN target. There is NO internet
// leg in this build (it needs an Academy-operated endpoint; MVP spec §3).
@interface NUSpeedTestEngine : NSObject
@property (nonatomic, copy, nullable) NUSpeedCompletionBlock onCompletion;
- (void)runGatewayLeg;
- (void)runLANLegWithTarget:(NUTarget *)target;
- (void)cancel;
@end

NS_ASSUME_NONNULL_END
