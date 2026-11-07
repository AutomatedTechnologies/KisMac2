//
//  NUTarget.m
//  Network Utility (Switchboard V1) — TargetKit implementation.
//  See NUTarget.h and Switchboard 02-DIAGNOSE-DESIGN.md §1.
//

#import "NUTarget.h"

#import <arpa/inet.h>
#import <netdb.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <string.h>

static const NSUInteger kNUMaxResolvedAddresses = 32;
static const NSUInteger kNUMaxDisplayLength = 255;

@interface NUTarget ()
@property (nonatomic) NUTargetKind kind;
@property (nonatomic, copy, nullable) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *hostname;
@property (nonatomic, copy, nullable) NSString *ipString;
@property (nonatomic, copy, nullable) NSString *ssid;
@property (nonatomic, copy, nullable) NSString *bssid;
@property (nonatomic) NSInteger channel;
@property (nonatomic, copy, nullable) NSString *modelHint;
@property (nonatomic) int addressFamily;              // AF_INET / AF_INET6 / AF_UNSPEC
@property (nonatomic) unsigned int scopeID;           // IPv6 zone, 0 = none
@property (nonatomic, copy, nullable) NSData *literalSockaddr; // for IP literals
@end

@implementation NUTarget

#pragma mark - Sanitizing

+ (NSString *)sanitizedDisplayString:(NSString *)raw
{
    if (raw == nil) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:MIN(raw.length, kNUMaxDisplayLength)];
    NSUInteger n = raw.length;
    for (NSUInteger i = 0; i < n && out.length < kNUMaxDisplayLength; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c < 0x20 || c == 0x7F) continue;   // strip control characters
        [out appendFormat:@"%C", c];
    }
    return [out copy];
}

#pragma mark - Hostname validation

// Returns the ASCII (A-label) form of the input, or nil + error.
+ (nullable NSString *)validatedHostname:(NSString *)input
                                   error:(NSString * _Nullable * _Nullable)error
{
    NSString *s = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) {
        if (error) *error = @"Enter a host name or IP address.";
        return nil;
    }
    // Hard rejections first: anything that could never be a hostname.
    // (Defense in depth — there is no shell anywhere in this product, but a
    // string that is not a hostname must not reach a log, a UI, or the wire.)
    NSCharacterSet *forbidden = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n/:@?#[]!$&'()*+,;=\"<>\\^`{|}~"];
    if ([s rangeOfCharacterFromSet:forbidden].location != NSNotFound ||
        [s rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        if (error) *error = @"That is not a valid host name.";
        return nil;
    }
    if ([s hasSuffix:@"."]) s = [s substringToIndex:s.length - 1];  // FQDN root dot

    // Non-ASCII: transliterate to Latin, strip diacritics, then validate the
    // result as LDH. The wire only ever sees the ASCII form.
    BOOL nonASCII = NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        if ([s characterAtIndex:i] > 0x7E) { nonASCII = YES; break; }
    }
    if (nonASCII) {
        NSMutableString *m = [s mutableCopy];
        CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformToLatin, FALSE);
        CFStringTransform((__bridge CFMutableStringRef)m, NULL, kCFStringTransformStripDiacritics, FALSE);
        s = [m copy];
        for (NSUInteger i = 0; i < s.length; i++) {
            if ([s characterAtIndex:i] > 0x7E) {
                if (error) *error = @"That host name cannot be converted to its ASCII (A-label) form.";
                return nil;
            }
        }
    }

    if (s.length == 0 || s.length > 253) {
        if (error) *error = @"Host names are at most 253 characters.";
        return nil;
    }
    NSCharacterSet *ldh = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"];
    for (NSString *label in [s componentsSeparatedByString:@"."]) {
        if (label.length == 0 || label.length > 63 ||
            [label hasPrefix:@"-"] || [label hasSuffix:@"-"] ||
            [label rangeOfCharacterFromSet:[ldh invertedSet]].location != NSNotFound) {
            if (error) *error = @"That is not a valid host name (labels are letters, digits and hyphens, 1–63 characters).";
            return nil;
        }
    }
    return [s lowercaseString];
}

#pragma mark - Classification

+ (NUTargetClass)classForSockaddr:(const struct sockaddr *)sa
{
    if (sa == NULL) return NUTargetClassUnknown;
    if (sa->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
        uint32_t a = ntohl(sin->sin_addr.s_addr);
        if (a == INADDR_ANY) return NUTargetClassUnspecified;
        if ((a >> 24) == 127) return NUTargetClassLoopback;
        if ((a >> 16) == 0xA9FE) return NUTargetClassLinkLocal;          // 169.254/16
        if ((a >> 24) == 10) return NUTargetClassPrivate;                // 10/8
        if ((a >> 20) == 0xAC1) return NUTargetClassPrivate;             // 172.16/12
        if ((a >> 16) == 0xC0A8) return NUTargetClassPrivate;            // 192.168/16
        if ((a >> 28) == 0xE) return NUTargetClassMulticast;             // 224/4
        return NUTargetClassPublic;
    }
    if (sa->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)sa;
        const uint8_t *b = sin6->sin6_addr.s6_addr;
        if (IN6_IS_ADDR_UNSPECIFIED(&sin6->sin6_addr)) return NUTargetClassUnspecified;
        if (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr)) return NUTargetClassLoopback;
        if (IN6_IS_ADDR_LINKLOCAL(&sin6->sin6_addr)) return NUTargetClassLinkLocal;
        if (IN6_IS_ADDR_MULTICAST(&sin6->sin6_addr)) return NUTargetClassMulticast;
        if ((b[0] & 0xFE) == 0xFC) return NUTargetClassPrivate;         // fc00::/7 ULA
        return NUTargetClassPublic;
    }
    return NUTargetClassUnknown;
}

#pragma mark - Constructors

+ (nullable instancetype)targetWithHostname:(NSString *)input
                                      error:(NSString * _Nullable * _Nullable)error
{
    NSString *host = [self validatedHostname:input error:error];
    if (host == nil) return nil;
    // A string of digits and dots that failed inet_pton is not a hostname
    // either — refuse it here so it cannot slip through as a "name".
    BOOL digitsAndDotsOnly = YES;
    for (NSUInteger i = 0; i < host.length; i++) {
        unichar c = [host characterAtIndex:i];
        if (!(c >= '0' && c <= '9') && c != '.') { digitsAndDotsOnly = NO; break; }
    }
    if (digitsAndDotsOnly) {
        if (error) *error = @"That IP address is not valid.";
        return nil;
    }
    NUTarget *t = [[self alloc] init];
    t.kind = NUTargetKindHost;
    t.hostname = host;
    t.displayName = [self sanitizedDisplayString:input];
    t.addressFamily = AF_UNSPEC;
    return t;
}

+ (nullable instancetype)targetWithIPLiteral:(NSString *)input
                                       error:(NSString * _Nullable * _Nullable)error
{
    NSString *s = [input stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) {
        if (error) *error = @"Enter a host name or IP address.";
        return nil;
    }
    unsigned int scopeID = 0;
    NSString *addrPart = s;
    NSRange pct = [s rangeOfString:@"%"];
    if (pct.location != NSNotFound) {
        addrPart = [s substringToIndex:pct.location];
        NSString *zone = [s substringFromIndex:pct.location + 1];
        if (zone.length == 0) {
            if (error) *error = @"That IPv6 zone is not valid.";
            return nil;
        }
        scopeID = if_nametoindex(zone.UTF8String);
        if (scopeID == 0) {
            if (error) *error = @"That IPv6 zone does not match a network interface on this Mac.";
            return nil;
        }
    }
    struct sockaddr_in sin;
    memset(&sin, 0, sizeof(sin));
    if (inet_pton(AF_INET, addrPart.UTF8String, &sin.sin_addr) == 1) {
        sin.sin_family = AF_INET;
        sin.sin_len = sizeof(sin);
        NUTarget *t = [[self alloc] init];
        t.kind = NUTargetKindHost;
        t.addressFamily = AF_INET;
        t.ipString = s;
        t.displayName = s;
        t.literalSockaddr = [NSData dataWithBytes:&sin length:sizeof(sin)];
        return t;
    }
    struct sockaddr_in6 sin6;
    memset(&sin6, 0, sizeof(sin6));
    if (inet_pton(AF_INET6, addrPart.UTF8String, &sin6.sin6_addr) == 1) {
        sin6.sin6_family = AF_INET6;
        sin6.sin6_len = sizeof(sin6);
        sin6.sin6_scope_id = scopeID;
        NUTarget *t = [[self alloc] init];
        t.kind = NUTargetKindHost;
        t.addressFamily = AF_INET6;
        t.scopeID = scopeID;
        t.ipString = s;
        t.displayName = s;
        t.literalSockaddr = [NSData dataWithBytes:&sin6 length:sizeof(sin6)];
        return t;
    }
    if (error) *error = @"That IP address is not valid.";
    return nil;
}

+ (nullable instancetype)targetWithHostInput:(NSString *)input
                                       error:(NSString * _Nullable * _Nullable)error
{
    NSString *ipError = nil;
    NUTarget *t = [self targetWithIPLiteral:input error:&ipError];
    if (t != nil) return t;
    return [self targetWithHostname:input error:error];
}

+ (instancetype)targetWithNetworkSSID:(NSString *)ssid
                                bssid:(NSString *)bssid
                              channel:(NSInteger)channel
{
    NUTarget *t = [[self alloc] init];
    t.kind = NUTargetKindNetwork;
    t.ssid = [self sanitizedDisplayString:ssid];
    t.bssid = [self sanitizedDisplayString:bssid];
    t.channel = channel;
    t.displayName = t.ssid.length > 0 ? t.ssid : @"(hidden network)";
    t.addressFamily = AF_UNSPEC;
    return t;
}

+ (nullable instancetype)targetWithBaseStationName:(NSString *)name
                                         ipLiteral:(NSString *)ipLiteral
                                         modelHint:(NSString *)modelHint
                                             error:(NSString * _Nullable * _Nullable)error
{
    NSString *ipError = nil;
    NUTarget *inner = [self targetWithIPLiteral:ipLiteral error:&ipError];
    if (inner == nil) {
        if (error) *error = ipError;
        return nil;
    }
    NUTarget *t = [[self alloc] init];
    t.kind = NUTargetKindBaseStation;
    t.displayName = [self sanitizedDisplayString:name];
    t.ipString = inner.ipString;
    t.addressFamily = inner.addressFamily;
    t.scopeID = inner.scopeID;
    t.literalSockaddr = inner.literalSockaddr;
    t.modelHint = [self sanitizedDisplayString:modelHint];
    return t;
}

#pragma mark - Classification & policy

- (NUTargetClass)targetClass
{
    if (self.literalSockaddr != nil) {
        return [[self class] classForSockaddr:(const struct sockaddr *)self.literalSockaddr.bytes];
    }
    if (self.hostname != nil) {
        NSString *err = nil;
        NSArray<NSData *> *addrs = [self resolvedSockaddrsWithError:&err];
        if (addrs.count > 0) {
            return [[self class] classForSockaddr:(const struct sockaddr *)addrs.firstObject.bytes];
        }
    }
    return NUTargetClassUnknown;
}

- (BOOL)activeProbingAllowed:(NSString * _Nullable * _Nullable)reason
{
    NUTargetClass c = [self targetClass];
    if (c == NUTargetClassMulticast) {
        if (reason) *reason = @"Multicast targets are refused — probing them can amplify traffic.";
        return NO;
    }
    if (c == NUTargetClassUnspecified) {
        if (reason) *reason = @"The unspecified address (0.0.0.0 / ::) is not a probe target.";
        return NO;
    }
    if (c == NUTargetClassUnknown) {
        if (reason) *reason = @"The target could not be resolved to an address.";
        return NO;
    }
    return YES;
}

#pragma mark - Resolution

+ (nullable NSString *)canonicalStringForSockaddr:(NSData *)sockaddrData
{
    if (sockaddrData == nil) return nil;
    char buf[NI_MAXHOST];
    const struct sockaddr *sa = (const struct sockaddr *)sockaddrData.bytes;
    socklen_t len = (sa->sa_family == AF_INET6) ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);
    if (getnameinfo(sa, len, buf, sizeof(buf), NULL, 0, NI_NUMERICHOST) != 0) return nil;
    return @(buf);
}

- (nullable NSArray<NSData *> *)resolvedSockaddrsWithError:(NSString * _Nullable * _Nullable)error
{
    if (self.literalSockaddr != nil) return @[self.literalSockaddr];
    if (self.hostname == nil) {
        if (error) *error = @"This target has no address to resolve.";
        return nil;
    }
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    hints.ai_flags = AI_ADDRCONFIG;
    struct addrinfo *res = NULL;
    int rc = getaddrinfo(self.hostname.UTF8String, NULL, &hints, &res);
    if (rc != 0 || res == NULL) {
        if (error) *error = [NSString stringWithFormat:@"Could not resolve %@: %s", self.hostname, gai_strerror(rc)];
        if (res) freeaddrinfo(res);
        return nil;
    }
    NSMutableArray<NSData *> *out = [NSMutableArray array];
    for (struct addrinfo *ai = res; ai != NULL && out.count < kNUMaxResolvedAddresses; ai = ai->ai_next) {
        if (ai->ai_family != AF_INET && ai->ai_family != AF_INET6) continue;
        NSData *d = [NSData dataWithBytes:ai->ai_addr length:(NSUInteger)ai->ai_addrlen];
        if (![out containsObject:d]) [out addObject:d];
    }
    freeaddrinfo(res);
    if (out.count == 0) {
        if (error) *error = [NSString stringWithFormat:@"Could not resolve %@.", self.hostname];
        return nil;
    }
    return [out copy];
}

#pragma mark - Description / copying

- (NSString *)validatedDescription
{
    switch (self.kind) {
        case NUTargetKindNetwork:
            return [NSString stringWithFormat:@"network %@ (%@) ch %ld",
                    self.ssid ?: @"(hidden)", self.bssid ?: @"?", (long)self.channel];
        case NUTargetKindBaseStation:
            return [NSString stringWithFormat:@"base-station %@ (%@)",
                    self.displayName ?: @"?", self.ipString ?: @"?"];
        case NUTargetKindHost:
        default:
            return self.ipString ?: (self.hostname ?: @"?");
    }
}

- (id)copyWithZone:(NSZone *)zone
{
    NUTarget *t = [[[self class] allocWithZone:zone] init];
    t.kind = self.kind;
    t.displayName = self.displayName;
    t.hostname = self.hostname;
    t.ipString = self.ipString;
    t.ssid = self.ssid;
    t.bssid = self.bssid;
    t.channel = self.channel;
    t.modelHint = self.modelHint;
    t.addressFamily = self.addressFamily;
    t.scopeID = self.scopeID;
    t.literalSockaddr = self.literalSockaddr;
    return t;
}

@end
