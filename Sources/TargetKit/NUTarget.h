//
//  NUTarget.h
//  Network Utility (Switchboard V1) — TargetKit
//
//  The single target-validation layer every Network Utility module consumes
//  (Switchboard 02-DIAGNOSE-DESIGN.md §1). Validation exists exactly once,
//  here; panels and protocol clients never parse user input themselves.
//
//  A target is one of: a network (from Discover), a base station (from
//  Manage), or a host (hostname / IP literal, validated below). All address
//  parsing of literals goes through inet_pton() into binary sockaddr form;
//  no hand-rolled IP parser exists in this codebase. Display strings are
//  sanitized; logs store only the validated form.
//
//  Part of the Academy-maintained KisMac2 / Network Utility product.
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>
#import <sys/socket.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NUTargetKind) {
    NUTargetKindHost        = 0,
    NUTargetKindNetwork     = 1,
    NUTargetKindBaseStation = 2,
};

typedef NS_ENUM(NSInteger, NUTargetClass) {
    NUTargetClassUnknown     = 0,
    NUTargetClassLoopback    = 1,
    NUTargetClassLinkLocal   = 2,
    NUTargetClassPrivate     = 3,
    NUTargetClassPublic      = 4,
    NUTargetClassMulticast   = 5,
    NUTargetClassUnspecified = 6,
};

@interface NUTarget : NSObject <NSCopying>

@property (nonatomic, readonly) NUTargetKind kind;

// Host / base-station identity (sanitized display form; wire form is the
// A-label hostname or the canonical IP string).
@property (nonatomic, copy, readonly, nullable) NSString *displayName;
@property (nonatomic, copy, readonly, nullable) NSString *hostname;   // ASCII (A-label) form, nil for pure IP literals
@property (nonatomic, copy, readonly, nullable) NSString *ipString;   // canonical form for IP literals, else nil

// Network identity (Discover).
@property (nonatomic, copy, readonly, nullable) NSString *ssid;
@property (nonatomic, copy, readonly, nullable) NSString *bssid;
@property (nonatomic, readonly) NSInteger channel;

// Base-station identity (Manage).
@property (nonatomic, copy, readonly, nullable) NSString *modelHint;

// -- Constructors. Each returns nil and fills *error with a plain-language
//    reason when the input is not a valid target of that kind. -------------

// Hostname path: LDH grammar per label (letters/digits/hyphen, 1-63 chars,
// <=253 total, no leading/trailing hyphen). Whitespace, control characters,
// URL schemes, userinfo, path separators and shell metacharacters are
// rejected outright. Non-ASCII input is transliterated to Latin and stripped
// of diacritics, then re-validated — the wire only ever sees ASCII.
+ (nullable instancetype)targetWithHostname:(NSString *)input
                                      error:(NSString * _Nullable * _Nullable)error;

// IP literal path: parsed ONLY by inet_pton(). IPv6 zone IDs (fe80::1%en0)
// are accepted; the interface name is validated against the live list.
+ (nullable instancetype)targetWithIPLiteral:(NSString *)input
                                       error:(NSString * _Nullable * _Nullable)error;

// Accepts either of the two forms above (tries IP literal first).
+ (nullable instancetype)targetWithHostInput:(NSString *)input
                                       error:(NSString * _Nullable * _Nullable)error;

+ (instancetype)targetWithNetworkSSID:(nullable NSString *)ssid
                                bssid:(nullable NSString *)bssid
                              channel:(NSInteger)channel;

+ (nullable instancetype)targetWithBaseStationName:(NSString *)name
                                         ipLiteral:(NSString *)ipLiteral
                                         modelHint:(nullable NSString *)modelHint
                                             error:(NSString * _Nullable * _Nullable)error;

// -- Classification & policy ----------------------------------------------

// Class of an IP-literal target, or of the first resolved address of a
// hostname target (resolves synchronously; NUTargetClassUnknown on failure).
- (NUTargetClass)targetClass;

// Active-probing panels (Ping, Traceroute, Speed Test) must consult this:
// multicast and unspecified targets are refused, with the reason filled in.
- (BOOL)activeProbingAllowed:(NSString * _Nullable * _Nullable)reason;

// -- Resolution ------------------------------------------------------------

// Binary sockaddr list (NSData wrapping struct sockaddr), capped at 32.
// IP literals resolve to themselves. Hostnames use getaddrinfo().
- (nullable NSArray<NSData *> *)resolvedSockaddrsWithError:(NSString * _Nullable * _Nullable)error;

// Canonical numeric string for a sockaddr produced by this class.
+ (nullable NSString *)canonicalStringForSockaddr:(NSData *)sockaddrData;

// Strips control characters and caps length; used for every string that
// reaches the UI or a log (reverse-DNS names, Bonjour names, SSIDs).
+ (NSString *)sanitizedDisplayString:(nullable NSString *)raw;

// One-line validated description for journal/audit records.
- (NSString *)validatedDescription;

@end

NS_ASSUME_NONNULL_END
