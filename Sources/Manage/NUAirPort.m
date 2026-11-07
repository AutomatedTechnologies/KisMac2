//
//  NUAirPort.m
//  Network Utility (Switchboard V1) — Manage (READ). See NUAirPort.h.
//
//  READ ONLY. The transport in this file sends exactly one kind of session:
//  authenticate (when a password is supplied) and request the full property
//  set. There is no setprop, no apply, no reboot path — nothing in this
//  file can change a base station.
//

#import "NUAirPort.h"
#import "NUTarget.h"

#import <sys/socket.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>

static const uint16_t kACPPort = 5009;
static const NSTimeInterval kConnectTimeoutSeconds = 5.0;
static const NSTimeInterval kReadDeadlineSeconds = 10.0;

#pragma mark - Station

@interface NUAirPortStation ()
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy, nullable) NSString *ipAddress;
@property (nonatomic, copy) NSDictionary *txtRecord;
@property (nonatomic, copy) NSString *modelHint;
@end

@implementation NUAirPortStation

- (instancetype)initWithDisplayName:(NSString *)name
                         ipAddress:(NSString *)ip
                         txtRecord:(NSDictionary *)txt
{
    self = [super init];
    if (self) {
        _displayName = [name copy] ?: @"Base station";
        _ipAddress = [ip copy];
        _txtRecord = [txt copy] ?: @{};
        _modelHint = @"AirPort base station";
        NSString *model = txt[@"model"];
        if ([model isKindOfClass:[NSString class]] && model.length > 0) _modelHint = model;
    }
    return self;
}

@end

#pragma mark - Password masking

// Properties that must never reach a display surface, the journal, or the
// raw table: the admin password property and anything password-typed.
static BOOL NUIsPasswordKey(NSString *key)
{
    NSString *lower = key.lowercaseString;
    return [lower isEqualToString:@"sypw"] ||
           [lower containsString:@"password"] ||
           [lower hasSuffix:@"pw"];
}

#pragma mark - Client: view models (transport-independent)

@implementation NUAirPortClient

static NSString *NUStringifyValue(id value)
{
    if (value == nil || value == [NSNull null]) return @"—";
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value length] ? value : @"—";
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    if ([value isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)value;
        NSUInteger show = MIN((NSUInteger)16, d.length);
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *bytes = d.bytes;
        for (NSUInteger i = 0; i < show; i++) [hex appendFormat:@"%02x", bytes[i]];
        return [NSString stringWithFormat:@"%@%@ (%lu bytes)", hex, d.length > show ? @"…" : @"", (unsigned long)d.length];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        for (id item in (NSArray *)value) [parts addObject:NUStringifyValue(item)];
        return [parts componentsJoinedByString:@", "];
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"(%lu entries)", (unsigned long)[(NSDictionary *)value count]];
    }
    return [value description] ?: @"—";
}

static void NUAddRow(NSMutableArray<NSDictionary *> *rows, NSString *item, NSString *value)
{
    if (value == nil || [value isEqualToString:@"—"]) return;
    [rows addObject:@{@"item": item, @"value": value}];
}

static NSString *NUProductName(NSNumber *code)
{
    switch (code.integerValue) {
        case 0: case 1: return @"AirPort Base Station";
        case 3: return @"AirPort Extreme (802.11g)";
        case 102: return @"AirPort Express";
        case 104: return @"AirPort Extreme (802.11n, Fast Ethernet)";
        case 105: return @"AirPort Extreme (802.11n, Gigabit)";
        case 115: return @"AirPort Express (2nd generation)";
        case 119: return @"AirPort Time Capsule";
        case 120: return @"AirPort Extreme (802.11ac)";
        default: return [NSString stringWithFormat:@"AirPort product %@", code];
    }
}

static NSString *NUSecurityName(NSNumber *code)
{
    switch (code.integerValue) {
        case 0: return @"—";
        case 1: return @"None";
        case 2: return @"WEP";
        case 3: return @"WEP 128-bit";
        case 4: return @"WPA Personal";
        case 5: return @"WPA Enterprise";
        case 6: return @"WPA/WPA2 Personal";
        case 7: return @"WPA2 Personal";
        case 8: return @"WPA2 Enterprise";
        case 9: return @"WPA/WPA2 Enterprise";
        case 10: return @"WEP (Transitional Security Network)";
        case 11: return @"Personal Hotspot";
        case 12: return @"WPA3 Personal";
        default: return [NSString stringWithFormat:@"Security mode %@", code];
    }
}

static NSString *NUSharingName(NSNumber *code)
{
    switch (code.integerValue) {
        case 0: return @"Share a single public IP address (NAT + DHCP)";
        case 1: return @"Distribute a range of IP addresses (DHCP only)";
        case 2: return @"Share a single IP address using NAT only";
        case 3: return @"Off (Bridge Mode)";
        default: return [NSString stringWithFormat:@"Connection sharing %@", code];
    }
}

+ (NSArray<NSDictionary *> *)sectionsFromProperties:(NSDictionary *)properties
{
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    if (![properties isKindOfClass:[NSDictionary class]]) return @[];

    // Overview
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NUAddRow(rows, @"Name", NUStringifyValue(properties[@"syNm"]));
    if ([properties[@"syAP"] isKindOfClass:[NSNumber class]]) {
        NUAddRow(rows, @"Model", NUProductName(properties[@"syAP"]));
    }
    NUAddRow(rows, @"Firmware version", NUStringifyValue(properties[@"syVs"]));
    NUAddRow(rows, @"Description", NUStringifyValue(properties[@"syDs"]));
    NUAddRow(rows, @"Serial number", NUStringifyValue(properties[@"sySN"]));
    if (rows.count) [sections addObject:@{@"title": @"Overview", @"rows": [rows copy]}];

    // Wireless — the radio property list is nested under "WiFi" when present.
    NSDictionary *wifi = [properties[@"WiFi"] isKindOfClass:[NSDictionary class]] ? properties[@"WiFi"] : properties;
    rows = [NSMutableArray array];
    NUAddRow(rows, @"Network name (SSID)", NUStringifyValue(wifi[@"raNm"]));
    if ([properties[@"bsSM"] isKindOfClass:[NSNumber class]]) {
        NUAddRow(rows, @"Security", NUSecurityName(properties[@"bsSM"]));
    }
    if ([properties[@"bsRC"] isKindOfClass:[NSNumber class]]) {
        NSInteger ch = [properties[@"bsRC"] integerValue];
        NUAddRow(rows, @"Channel", ch == 1000 ? @"Automatic" : [NSString stringWithFormat:@"%ld", (long)ch]);
    }
    NUAddRow(rows, @"Radio mode", NUStringifyValue(wifi[@"raMd"]));
    NUAddRow(rows, @"Wireless mode", NUStringifyValue(properties[@"bsNM"]));
    NUAddRow(rows, @"Closed network", [wifi[@"raCl"] boolValue] ? @"Yes (SSID hidden)" : @"No");
    if (rows.count) [sections addObject:@{@"title": @"Wireless", @"rows": [rows copy]}];

    // Guest network — shown when the station reports any guest property.
    rows = [NSMutableArray array];
    for (NSString *key in [properties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([key.lowercaseString containsString:@"guest"] && !NUIsPasswordKey(key)) {
            NUAddRow(rows, key, NUStringifyValue(properties[key]));
        }
    }
    if (rows.count) [sections addObject:@{@"title": @"Guest Network", @"rows": [rows copy]}];

    // Network / WAN
    rows = [NSMutableArray array];
    if ([properties[@"bsRM"] isKindOfClass:[NSNumber class]]) {
        NUAddRow(rows, @"Connection sharing", NUSharingName(properties[@"bsRM"]));
    }
    NUAddRow(rows, @"WAN IP address", NUStringifyValue(properties[@"waIP"]));
    NUAddRow(rows, @"Subnet mask", NUStringifyValue(properties[@"waSM"]));
    NUAddRow(rows, @"Router address", NUStringifyValue(properties[@"waRA"]));
    NSMutableArray<NSString *> *dns = [NSMutableArray array];
    for (NSString *k in @[@"waD1", @"waD2", @"waD3"]) {
        NSString *v = NUStringifyValue(properties[k]);
        if (![v isEqualToString:@"—"]) [dns addObject:v];
    }
    if (dns.count) NUAddRow(rows, @"DNS servers", [dns componentsJoinedByString:@", "]);
    if (rows.count) [sections addObject:@{@"title": @"Network", @"rows": [rows copy]}];

    // Disks (Time Capsule) — read-only status.
    rows = [NSMutableArray array];
    id disks = properties[@"MaSt"];
    if ([disks isKindOfClass:[NSDictionary class]]) {
        for (NSString *name in [[(NSDictionary *)disks allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
            NUAddRow(rows, name, NUStringifyValue(disks[name]));
        }
    } else if (disks != nil) {
        NUAddRow(rows, @"Disks", NUStringifyValue(disks));
    }
    if ([properties[@"bsFS"] isKindOfClass:[NSNumber class]]) {
        NUAddRow(rows, @"File sharing", [properties[@"bsFS"] boolValue] ? @"On" : @"Off");
    }
    if (rows.count) [sections addObject:@{@"title": @"Disks", @"rows": [rows copy]}];

    return [sections copy];
}

+ (NSDictionary *)displayableRawProperties:(NSDictionary *)properties
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in properties.allKeys) {
        if (NUIsPasswordKey(key)) continue;
        id value = properties[key];
        if ([value isKindOfClass:[NSDictionary class]]) {
            // One level deep, same masking.
            NSMutableDictionary *sub = [NSMutableDictionary dictionary];
            for (NSString *sk in [(NSDictionary *)value allKeys]) {
                if (!NUIsPasswordKey(sk)) sub[sk] = NUStringifyValue(value[sk]);
            }
            out[key] = [sub copy];
        } else {
            out[key] = NUStringifyValue(value);
        }
    }
    return [out copy];
}

#pragma mark - Client: transport (the isolated ACP session; P2 rig-iteration surface)

// Attempts to recover a property dictionary from a received byte stream: the
// payload may be a binary or XML plist, possibly following session framing,
// so the stream is scanned for a plist payload rather than assumed aligned.
+ (nullable NSDictionary *)propertyPayloadInData:(NSData *)data
{
    if (data.length == 0) return nil;
    // Try the whole buffer, then a scan for plist magic at any offset.
    for (NSUInteger off = 0; off == 0 || off < data.length; ) {
        NSData *candidate = off == 0 ? data : [data subdataWithRange:NSMakeRange(off, data.length - off)];
        id plist = [NSPropertyListSerialization propertyListWithData:candidate
                                                               options:NSPropertyListImmutable
                                                                format:NULL
                                                                 error:nil];
        if ([plist isKindOfClass:[NSDictionary class]]) return plist;
        if (off >= data.length) break;
        // Advance to the next possible plist start.
        const uint8_t *bytes = data.bytes;
        NSUInteger next = NSNotFound;
        for (NSUInteger i = off + 1; i + 8 <= data.length; i++) {
            if (memcmp(bytes + i, "bplist00", 8) == 0 || memcmp(bytes + i, "<?xml", 5) == 0) { next = i; break; }
        }
        if (next == NSNotFound) break;
        off = next;
    }
    return nil;
}

+ (void)fetchConfigurationForStation:(NUAirPortStation *)station
                            password:(NSString *)password
                          completion:(NUAirPortFetchCompletion)completion
{
    NSString *ip = station.ipAddress;
    if (ip.length == 0) {
        completion(nil, nil, @"The station has no resolved IP address yet.");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = nil;
        NSDictionary *properties = [self readPropertiesFromIPv4:ip password:password error:&error];
        if (properties == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil, error ?: @"The station did not return a configuration."); });
            return;
        }
        NSArray<NSDictionary *> *sections = [self sectionsFromProperties:properties];
        NSDictionary *raw = [self displayableRawProperties:properties];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(sections, raw, nil); });
    });
}

// One read session over a plain socket. The request side follows the public
// ACP references (authenticate with the supplied password when given, then
// request the full property set). Any framing refinement against real
// hardware happens inside this method only (P2 verification surface); the
// rest of the app consumes parsed properties, never wire bytes.
+ (nullable NSDictionary *)readPropertiesFromIPv4:(NSString *)ip
                                         password:(nullable NSString *)password
                                            error:(NSString * _Nullable * _Nullable)error
{
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kACPPort);
    if (inet_pton(AF_INET, ip.UTF8String, &addr.sin_addr) != 1) {
        if (error) *error = @"Not a valid IPv4 address.";
        return nil;
    }
    int sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (sock < 0) {
        if (error) *error = @"Could not open a socket.";
        return nil;
    }
    // Bounded connect.
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(sock, (const struct sockaddr *)&addr, sizeof(addr));
    if (rc != 0 && errno == EINPROGRESS) {
        fd_set wfds;
        FD_ZERO(&wfds);
        FD_SET(sock, &wfds);
        struct timeval tv;
        tv.tv_sec = (time_t)kConnectTimeoutSeconds;
        tv.tv_usec = 0;
        rc = (select(sock + 1, NULL, &wfds, NULL, &tv) > 0) ? 0 : -1;
    }
    fcntl(sock, F_SETFL, flags);
    if (rc != 0) {
        close(sock);
        if (error) *error = [NSString stringWithFormat:@"Could not connect to %@ on port %u (the AirPort admin port).", ip, kACPPort];
        return nil;
    }
    struct timeval rtv;
    rtv.tv_sec = 2;
    rtv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &rtv, sizeof(rtv));

    // Read request: per the public ACP references the client authenticates
    // with the session password and requests all properties; the station
    // answers with its property payload. The supplied password travels only
    // inside this session and is never retained by this process afterwards.
    NSMutableData *request = [NSMutableData data];
    NSString *requestText = password.length > 0
        ? [NSString stringWithFormat:@"propget\tauth=%@\t*", password]
        : @"propget\t*";
    [request appendData:[requestText dataUsingEncoding:NSUTF8StringEncoding]];
    [request appendBytes:"\n" length:1];
    const uint8_t *reqBytes = request.bytes;
    NSUInteger sentTotal = 0;
    while (sentTotal < request.length) {
        ssize_t n = send(sock, reqBytes + sentTotal, request.length - sentTotal, 0);
        if (n <= 0) break;
        sentTotal += (NSUInteger)n;
    }

    NSMutableData *received = [NSMutableData data];
    double deadline = [NSDate timeIntervalSinceReferenceDate] + kReadDeadlineSeconds;
    uint8_t buf[8192];
    while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
        ssize_t n = recv(sock, buf, sizeof(buf), 0);
        if (n > 0) {
            [received appendBytes:buf length:(NSUInteger)n];
            if ([self propertyPayloadInData:received] != nil) break;
            continue;
        }
        if (n == 0) break;             // station closed the session
        if (errno == EAGAIN || errno == EWOULDBLOCK) continue;
        break;
    }
    close(sock);

    NSDictionary *properties = [self propertyPayloadInData:received];
    if (properties == nil) {
        if (error) {
            *error = received.length == 0
                ? @"The station accepted the connection but returned no configuration (authentication may be required)."
                : @"The station answered, but its configuration payload was not understood. (The admin-protocol transport is verified against real hardware in the P2 rig tranche.)";
        }
        return nil;
    }
    return properties;
}

@end

#pragma mark - Browser

@interface NUAirPortBrowser () <NSNetServiceBrowserDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableArray<NUAirPortStation *> *found;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *resolving;
@property (nonatomic, copy) NSArray<NUAirPortStation *> *stations;
@end

@implementation NUAirPortBrowser

- (instancetype)init
{
    self = [super init];
    if (self) {
        _found = [NSMutableArray array];
        _resolving = [NSMutableArray array];
        _stations = @[];
    }
    return self;
}

- (void)startBrowsing
{
    if (self.browser) return;
    self.browser = [[NSNetServiceBrowser alloc] init];
    self.browser.delegate = self;
    [self.browser searchForServicesOfType:@"_airport._tcp." inDomain:@"local."];
}

- (void)stopBrowsing
{
    [self.browser stop];
    self.browser = nil;
    for (NSNetService *s in self.resolving) [s stop];
    [self.resolving removeAllObjects];
}

- (void)publishChange
{
    self.stations = [self.found copy];
    if (self.onChange) self.onChange();
}

- (void)addStationWithTarget:(NUTarget *)target
{
    NSString *ip = target.ipString;
    if (ip.length == 0) return;
    NUAirPortStation *station = [[NUAirPortStation alloc] initWithDisplayName:ip ipAddress:ip txtRecord:@{}];
    [self.found addObject:station];
    [self publishChange];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    service.delegate = self;
    [self.resolving addObject:service];
    [service resolveWithTimeout:5.0];
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
         didRemoveService:(NSNetService *)service
               moreComing:(BOOL)moreComing
{
    NSMutableArray<NUAirPortStation *> *keep = [NSMutableArray array];
    for (NUAirPortStation *st in self.found) {
        if (![st.displayName isEqualToString:service.name]) [keep addObject:st];
    }
    self.found = keep;
    [self publishChange];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender
{
    NSString *ipv4 = nil;
    for (NSData *addrData in sender.addresses) {
        const struct sockaddr *sa = (const struct sockaddr *)addrData.bytes;
        if (sa->sa_family == AF_INET) {
            ipv4 = [NUTarget canonicalStringForSockaddr:addrData];
            if (ipv4) break;
        }
    }
    NSDictionary *txt = [NSNetService dictionaryFromTXTRecordData:sender.TXTRecordData ?: [NSData data]] ?: @{};
    // TXT values are NSData; stringify for the station record.
    NSMutableDictionary *txtStrings = [NSMutableDictionary dictionary];
    for (NSString *k in txt.allKeys) {
        id v = txt[k];
        if ([v isKindOfClass:[NSData class]]) {
            NSString *s = [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding];
            if (s) txtStrings[k] = s;
        } else if ([v isKindOfClass:[NSString class]]) {
            txtStrings[k] = v;
        }
    }
    NUAirPortStation *station = [[NUAirPortStation alloc] initWithDisplayName:sender.name
                                                                   ipAddress:ipv4
                                                                   txtRecord:[txtStrings copy]];
    BOOL replaced = NO;
    for (NSUInteger i = 0; i < self.found.count; i++) {
        if ([self.found[i].displayName isEqualToString:sender.name]) {
            self.found[i] = station;
            replaced = YES;
            break;
        }
    }
    if (!replaced) [self.found addObject:station];
    [self.resolving removeObject:sender];
    [self publishChange];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict
{
    [self.resolving removeObject:sender];
}

@end
