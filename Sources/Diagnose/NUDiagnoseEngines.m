//
//  NUDiagnoseEngines.m
//  Network Utility (Switchboard V1) — Diagnose engines. See header + design.
//
//  No shell: this file contains no NSTask, posix_spawn, or system() call and
//  links none. No privilege: ICMP uses the unprivileged datagram ping
//  socket (the SimplePing approach, design §2); traceroute uses ordinary
//  UDP probes with TTL plus the datagram ICMP receive socket (design §4);
//  netstat reads kernel tables in-process (design §8).
//

#import "NUDiagnoseEngines.h"

#import <sys/socket.h>
#import <sys/sysctl.h>
#import <sys/proc_info.h>
#import <netinet/in.h>
#import <netinet/ip.h>
#import <netinet/ip_icmp.h>
#import <netinet/icmp6.h>
#import <netinet/udp.h>
#import <net/if.h>
#import <net/route.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <libproc.h>
#import <unistd.h>
#import <string.h>
#import <math.h>
#import <errno.h>

static double NUNowSeconds(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// ICMPv4 checksum (used for the echo request; harmless if the kernel also
// maintains it for datagram ping sockets).
static uint16_t NUInChecksum(const void *data, size_t len)
{
    const uint16_t *p = (const uint16_t *)data;
    uint32_t sum = 0;
    while (len > 1) { sum += ntohs(*p); p++; len -= 2; }
    if (len) sum += ((const uint8_t *)p)[0] << 8;
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint16_t)~sum;
}

static NSString *NUIPStringForSockaddr(const struct sockaddr *sa)
{
    NSData *d = [NSData dataWithBytes:sa
                               length:(sa->sa_family == AF_INET6) ? sizeof(struct sockaddr_in6)
                                                                  : sizeof(struct sockaddr_in)];
    return [NUTarget canonicalStringForSockaddr:d] ?: @"?";
}

#pragma mark - Ping

@interface NUPingEngine ()
@property (nonatomic, strong) NUTarget *target;
@property (nonatomic) NSInteger count;
@property (nonatomic) NSTimeInterval interval;
@property (nonatomic) volatile BOOL cancelled;
@property (nonatomic) int sock;
@property (nonatomic, strong, nullable) NSThread *thread;
@end

@implementation NUPingEngine

- (instancetype)initWithTarget:(NUTarget *)target count:(NSInteger)count interval:(NSTimeInterval)interval
{
    self = [super init];
    if (self) {
        _target = target;
        _count = MAX(1, MIN(100, count));
        _interval = MAX(0.2, interval);
        _sock = -1;
    }
    return self;
}

- (void)start
{
    self.thread = [[NSThread alloc] initWithBlock:^{ [self runLoop]; }];
    self.thread.name = @"NU Ping";
    [self.thread start];
}

- (void)cancel
{
    self.cancelled = YES;
    if (self.sock >= 0) { close(self.sock); self.sock = -1; }
}

- (void)deliverCompletion:(NSDictionary *)stats error:(NSString *)error
{
    NUPingCompletionBlock cb = self.onCompletion;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(stats, error); });
}

// Echo payload layout (fixed 56-byte data field, design §2): the user
// controls count and interval only, never content.
//   [0..1] sequence (BE) · [2..5] session token (BE) · [6..13] send time
//   (monotonic double, host order — it is our own payload echoed back) ·
//   [14..55] fixed pattern.
static const NSUInteger kPingPayloadSize = 56;

- (void)runLoop
{
    @autoreleasepool {
        NSString *resolveError = nil;
        NSArray<NSData *> *addrs = [self.target resolvedSockaddrsWithError:&resolveError];
        if (addrs.count == 0) {
            [self deliverCompletion:@{} error:resolveError ?: @"Could not resolve the target."];
            return;
        }
        // Prefer IPv4 (the house LAN case); fall back to the first address.
        NSData *destData = addrs.firstObject;
        for (NSData *d in addrs) {
            if (((const struct sockaddr *)d.bytes)->sa_family == AF_INET) { destData = d; break; }
        }
        const struct sockaddr *dest = (const struct sockaddr *)destData.bytes;
        BOOL isV6 = (dest->sa_family == AF_INET6);
        int family = isV6 ? AF_INET6 : AF_INET;
        int proto = isV6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP;
        int sock = socket(family, SOCK_DGRAM, proto);
        if (sock < 0) {
            [self deliverCompletion:@{} error:[NSString stringWithFormat:@"Could not open the ping socket (%s).", strerror(errno)]];
            return;
        }
        self.sock = sock;

        uint32_t token = arc4random();
        uint16_t identifier = (uint16_t)(getpid() & 0xFFFF);
        NSInteger sent = 0, received = 0;
        double minMs = 0, maxMs = 0, sumMs = 0;
        NSMutableDictionary<NSNumber *, NSNumber *> *sendTimes = [NSMutableDictionary dictionary];
        double deadline = NUNowSeconds() + (double)self.count * self.interval + 3.0;
        double nextSend = NUNowSeconds();

        while (!self.cancelled && NUNowSeconds() < deadline) {
            double now = NUNowSeconds();
            if (sent < self.count && now >= nextSend) {
                uint8_t packet[8 + kPingPayloadSize];
                memset(packet, 0x2A, sizeof(packet));
                packet[0] = isV6 ? 128 : 8;    // echo request
                packet[1] = 0;                 // code
                packet[2] = 0; packet[3] = 0;  // checksum (v6: kernel; v4: set below)
                uint16_t idBE = htons(identifier);
                memcpy(packet + 4, &idBE, 2);
                uint16_t seqBE = htons((uint16_t)sent);
                memcpy(packet + 6, &seqBE, 2);
                uint16_t pseqBE = htons((uint16_t)sent);
                memcpy(packet + 8, &pseqBE, 2);
                uint32_t tokenBE = htonl(token);
                memcpy(packet + 10, &tokenBE, 4);
                double t = NUNowSeconds();
                memcpy(packet + 14, &t, 8);
                if (!isV6) {
                    uint16_t cks = NUInChecksum(packet, sizeof(packet));
                    uint16_t cksBE = htons(cks);
                    memcpy(packet + 2, &cksBE, 2);
                }
                ssize_t n = sendto(sock, packet, sizeof(packet), 0, dest,
                                   isV6 ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in));
                if (n >= 0) {
                    sendTimes[@(sent)] = @(t);
                    sent++;
                }
                nextSend = now + self.interval;
            }
            if (received >= sent && sent >= self.count) break;

            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(sock, &rfds);
            struct timeval tv;
            tv.tv_sec = 0;
            tv.tv_usec = 50000; // 50 ms slices keep cancel latency low
            int ready = select(sock + 1, &rfds, NULL, NULL, &tv);
            if (ready > 0 && FD_ISSET(sock, &rfds)) {
                uint8_t buf[2048];
                struct sockaddr_storage from;
                socklen_t fromLen = sizeof(from);
                ssize_t n = recvfrom(sock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromLen);
                if (n >= (ssize_t)(8 + 14)) {
                    uint8_t type = buf[0];
                    BOOL isReply = isV6 ? (type == 129) : (type == 0);
                    if (isReply) {
                        uint16_t seq;
                        memcpy(&seq, buf + 8, 2);
                        seq = ntohs(seq);
                        uint32_t rtok;
                        memcpy(&rtok, buf + 10, 4);
                        if (ntohl(rtok) == token && sendTimes[@(seq)] != nil) {
                            double sentAt = sendTimes[@(seq)].doubleValue;
                            [sendTimes removeObjectForKey:@(seq)];
                            double rtt = (NUNowSeconds() - sentAt) * 1000.0;
                            received++;
                            sumMs += rtt;
                            if (received == 1 || rtt < minMs) minMs = rtt;
                            if (rtt > maxMs) maxMs = rtt;
                            NUPingReplyBlock rb = self.onReply;
                            if (rb) {
                                uint16_t s = seq; double r = rtt;
                                dispatch_async(dispatch_get_main_queue(), ^{ rb(s, r); });
                            }
                        }
                    }
                }
            }
            if (sent >= self.count && sendTimes.count == 0) break;
        }

        if (self.sock >= 0) { close(self.sock); self.sock = -1; }
        if (self.cancelled) {
            [self deliverCompletion:@{} error:@"Stopped."];
            return;
        }
        double loss = sent > 0 ? (100.0 * (double)(sent - received) / (double)sent) : 0;
        NSDictionary *stats = @{
            @"sent": @(sent),
            @"received": @(received),
            @"lossPercent": @(loss),
            @"minMs": @(received ? minMs : 0),
            @"avgMs": @(received ? sumMs / (double)received : 0),
            @"maxMs": @(maxMs),
        };
        [self deliverCompletion:stats error:nil];
    }
}

@end

#pragma mark - Traceroute

@interface NUTracerouteEngine ()
@property (nonatomic, strong) NUTarget *target;
@property (nonatomic) NSInteger maxHops;
@property (nonatomic) NSTimeInterval probeTimeout;
@property (nonatomic) volatile BOOL cancelled;
@property (nonatomic) int recvSock;
@property (nonatomic) int sendSock;
@property (nonatomic, strong, nullable) NSThread *thread;
@end

@implementation NUTracerouteEngine

static const uint16_t kTraceBasePort = 33434;

- (instancetype)initWithTarget:(NUTarget *)target maxHops:(NSInteger)maxHops probeTimeout:(NSTimeInterval)probeTimeout
{
    self = [super init];
    if (self) {
        _target = target;
        _maxHops = MAX(1, MIN(64, maxHops));
        _probeTimeout = MAX(1.0, MIN(5.0, probeTimeout));
        _recvSock = -1;
        _sendSock = -1;
    }
    return self;
}

- (void)start
{
    self.thread = [[NSThread alloc] initWithBlock:^{ [self runLoop]; }];
    self.thread.name = @"NU Traceroute";
    [self.thread start];
}

- (void)cancel
{
    self.cancelled = YES;
    if (self.recvSock >= 0) { close(self.recvSock); self.recvSock = -1; }
    if (self.sendSock >= 0) { close(self.sendSock); self.sendSock = -1; }
}

- (void)deliverHop:(NSInteger)hop responder:(NSString *)ip rtts:(NSArray<NSNumber *> *)rtts reached:(BOOL)reached
{
    NUTracerouteHopBlock hb = self.onHop;
    if (hb) dispatch_async(dispatch_get_main_queue(), ^{ hb(hop, ip, rtts, reached); });
}

- (void)deliverCompletion:(NSString *)error
{
    NUTracerouteCompletionBlock cb = self.onCompletion;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(error); });
}

// IPv4 traceroute per design §4: UDP probes to a high destination port with
// incrementing TTL on an ordinary datagram socket; replies read on the
// datagram ICMP socket. An ICMP error quotes the original IP header + the
// first 8 bytes of the original datagram (the UDP header) — the probe is
// matched by its destination port. Port Unreachable (type 3, code 3) from
// the target ends the trace.
- (void)runLoop
{
    @autoreleasepool {
        NSString *resolveError = nil;
        NSArray<NSData *> *addrs = [self.target resolvedSockaddrsWithError:&resolveError];
        NSData *destData = nil;
        for (NSData *d in addrs) {
            if (((const struct sockaddr *)d.bytes)->sa_family == AF_INET) { destData = d; break; }
        }
        if (destData == nil) {
            [self deliverCompletion:@"Traceroute in this build traces IPv4 targets; this target has no IPv4 address."];
            return;
        }
        struct sockaddr_in dest;
        memcpy(&dest, destData.bytes, sizeof(dest));

        int sendSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        int recvSock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
        if (sendSock < 0 || recvSock < 0) {
            if (sendSock >= 0) close(sendSock);
            if (recvSock >= 0) close(recvSock);
            [self deliverCompletion:[NSString stringWithFormat:@"Could not open trace sockets (%s).", strerror(errno)]];
            return;
        }
        self.sendSock = sendSock;
        self.recvSock = recvSock;

        BOOL reached = NO;
        uint16_t probeSeq = 0;
        for (NSInteger ttl = 1; ttl <= self.maxHops && !reached && !self.cancelled; ttl++) {
            int ttlVal = (int)ttl;
            setsockopt(sendSock, IPPROTO_IP, IP_TTL, &ttlVal, sizeof(ttlVal));

            NSMutableDictionary<NSNumber *, NSNumber *> *pending = [NSMutableDictionary dictionary]; // port -> send time
            for (int probe = 0; probe < 3; probe++) {
                uint16_t port = kTraceBasePort + (uint16_t)(probeSeq++);
                struct sockaddr_in dst = dest;
                dst.sin_port = htons(port);
                uint8_t payload[32];
                memset(payload, 0x54, sizeof(payload));
                double t = NUNowSeconds();
                ssize_t n = sendto(sendSock, payload, sizeof(payload), 0,
                                   (const struct sockaddr *)&dst, sizeof(dst));
                if (n >= 0) pending[@(port)] = @(t);
            }

            NSMutableArray<NSNumber *> *rtts = [NSMutableArray array];
            NSString *responder = nil;
            double windowEnd = NUNowSeconds() + self.probeTimeout;
            while (!self.cancelled && pending.count > 0 && NUNowSeconds() < windowEnd) {
                fd_set rfds;
                FD_ZERO(&rfds);
                FD_SET(recvSock, &rfds);
                struct timeval tv = {0, 50000};
                int ready = select(recvSock + 1, &rfds, NULL, NULL, &tv);
                if (ready <= 0 || !FD_ISSET(recvSock, &rfds)) continue;
                uint8_t buf[2048];
                struct sockaddr_in from;
                socklen_t fromLen = sizeof(from);
                ssize_t n = recvfrom(recvSock, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fromLen);
                if (n < 8) continue;
                NSUInteger off = 0;
                if ((buf[0] >> 4) == 4 && n >= 20) off = (buf[0] & 0x0F) * 4; // outer IP header present (raw-style delivery)
                if (n < (ssize_t)(off + 8)) continue;
                uint8_t type = buf[off];
                uint8_t code = buf[off + 1];
                if (type != 11 && type != 3) continue;   // Time Exceeded / Destination Unreachable
                // Quoted original packet starts after the 8-byte ICMP header.
                NSUInteger q = off + 8;
                if (n < (ssize_t)(q + 20)) continue;
                if ((buf[q] >> 4) != 4) continue;
                NSUInteger ihl = (buf[q] & 0x0F) * 4;
                if (n < (ssize_t)(q + ihl + 4) || buf[q + 9] != IPPROTO_UDP) continue;
                uint16_t dstPort;
                memcpy(&dstPort, buf + q + ihl + 2, 2);
                dstPort = ntohs(dstPort);
                NSNumber *sentAt = pending[@(dstPort)];
                if (sentAt == nil) continue;
                [pending removeObjectForKey:@(dstPort)];
                double rtt = (NUNowSeconds() - sentAt.doubleValue) * 1000.0;
                [rtts addObject:@(rtt)];
                responder = NUIPStringForSockaddr((const struct sockaddr *)&from);
                if (type == 3 && code == 3) reached = YES;  // port unreachable: the target itself
            }
            [self deliverHop:ttl responder:responder rtts:[rtts copy] reached:reached];
        }

        if (self.sendSock >= 0) { close(self.sendSock); self.sendSock = -1; }
        if (self.recvSock >= 0) { close(self.recvSock); self.recvSock = -1; }
        [self deliverCompletion:self.cancelled ? @"Stopped." : nil];
    }
}

@end

#pragma mark - Netstat

#define NU_SA_SIZE(sa) \
    (((sa)->sa_len == 0) ? (socklen_t)sizeof(uint32_t) \
                         : (socklen_t)(1 + (((sa)->sa_len - 1) | (sizeof(long) - 1))))

static NSString *NUFlagsString(int flags)
{
    NSMutableString *s = [NSMutableString string];
    if (flags & RTF_UP) [s appendString:@"U"];
    if (flags & RTF_GATEWAY) [s appendString:@"G"];
    if (flags & RTF_HOST) [s appendString:@"H"];
    if (flags & RTF_REJECT) [s appendString:@"R"];
    if (flags & RTF_DYNAMIC) [s appendString:@"D"];
    if (flags & RTF_MODIFIED) [s appendString:@"M"];
    if (flags & RTF_STATIC) [s appendString:@"S"];
    if (flags & RTF_LLINFO) [s appendString:@"L"];
    if (flags & RTF_WASCLONED) [s appendString:@"W"];
    return [s copy];
}

static NSInteger NUPrefixLength(const struct sockaddr *mask, NSInteger family)
{
    if (mask == NULL) return (family == AF_INET6) ? 128 : 32;
    NSInteger bits = 0;
    if (family == AF_INET) {
        uint32_t m = ntohl(((const struct sockaddr_in *)mask)->sin_addr.s_addr);
        while (m & 0x80000000) { bits++; m <<= 1; }
        return bits;
    }
    const uint8_t *b = ((const struct sockaddr_in6 *)mask)->sin6_addr.s6_addr;
    for (int i = 0; i < 16; i++) {
        uint8_t byte = b[i];
        while (byte & 0x80) { bits++; byte = (uint8_t)(byte << 1); }
        if (byte != 0) break;
    }
    return bits;
}

// Parses the NET_RT_DUMP buffer in-process with per-record bounds checks
// (design §8: kernel data, parsed defensively — lengths come from the
// buffer and are never trusted blindly).
static NSArray<NSDictionary *> *NURouteRecords(void)
{
    int mib[6] = {CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0};
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) != 0 || len == 0) return @[];
    char *buf = (char *)malloc(len);
    if (buf == NULL) return @[];
    if (sysctl(mib, 6, buf, &len, NULL, 0) != 0) { free(buf); return @[]; }

    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    char *end = buf + len;
    for (char *p = buf; p + (ptrdiff_t)sizeof(struct rt_msghdr) <= end;) {
        struct rt_msghdr *rtm = (struct rt_msghdr *)p;
        if (rtm->rtm_msglen < sizeof(struct rt_msghdr) || p + rtm->rtm_msglen > end) break;
        if ((rtm->rtm_version) == RTM_VERSION) {
            const struct sockaddr *sa[RTAX_MAX];
            memset(sa, 0, sizeof(sa));
            char *cp = (char *)(rtm + 1);
            char *recEnd = p + rtm->rtm_msglen;
            BOOL ok = YES;
            for (int i = 0; i < RTAX_MAX; i++) {
                if (rtm->rtm_addrs & (1 << i)) {
                    if (cp + (ptrdiff_t)sizeof(struct sockaddr) > recEnd) { ok = NO; break; }
                    const struct sockaddr *s = (const struct sockaddr *)cp;
                    socklen_t adv = NU_SA_SIZE(s);
                    if (cp + adv > recEnd) { ok = NO; break; }
                    sa[i] = s;
                    cp += adv;
                }
            }
            if (ok && sa[RTAX_DST] != NULL &&
                (sa[RTAX_DST]->sa_family == AF_INET || sa[RTAX_DST]->sa_family == AF_INET6)) {
                int fam = sa[RTAX_DST]->sa_family;
                NSString *dst = NUIPStringForSockaddr(sa[RTAX_DST]);
                NSInteger plen = NUPrefixLength(sa[RTAX_NETMASK], fam);
                char ifname[IFNAMSIZ] = {0};
                if_indextoname(rtm->rtm_index, ifname);
                NSMutableDictionary *row = [@{
                    @"destination": [NSString stringWithFormat:@"%@/%ld", dst, (long)plen],
                    @"gateway": sa[RTAX_GATEWAY] ? NUIPStringForSockaddr(sa[RTAX_GATEWAY]) : @"—",
                    @"flags": NUFlagsString(rtm->rtm_flags),
                    @"interface": @(ifname),
                    @"family": @(fam),
                    @"isDefault": @([dst isEqualToString:@"0.0.0.0"] || [dst isEqualToString:@"::"]),
                } mutableCopy];
                [rows addObject:row];
            }
        }
        p += rtm->rtm_msglen;
    }
    free(buf);
    return [rows copy];
}

@implementation NUNetstat

+ (NSString *)routingTableText
{
    NSArray<NSDictionary *> *rows = NURouteRecords();
    NSMutableString *out = [NSMutableString stringWithString:
        @"Routing table (kernel data, read in-process)\n\nDestination             Gateway                 Flags  Interface\n"];
    for (NSDictionary *r in rows) {
        [out appendFormat:@"%-24s%-24s%-7s%s\n",
            [r[@"destination"] UTF8String], [r[@"gateway"] UTF8String],
            [r[@"flags"] UTF8String], [r[@"interface"] UTF8String]];
    }
    if (rows.count == 0) [out appendString:@"(no routes returned)\n"];
    return [out copy];
}

+ (NSString *)interfaceTableText
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || list == NULL) return @"Interfaces: unavailable.\n";
    NSMutableString *out = [NSMutableString stringWithString:@"Interfaces\n\n"];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        NSString *name = @(ifa->ifa_name);
        if ([seen containsObject:name]) continue;
        [seen addObject:name];
        // Find this interface's link entry for MTU / negotiated rate.
        struct if_data *data = NULL;
        NSMutableArray<NSString *> *addrs = [NSMutableArray array];
        unsigned int flags = ifa->ifa_flags;
        for (struct ifaddrs *j = list; j != NULL; j = j->ifa_next) {
            if (strcmp(j->ifa_name, ifa->ifa_name) != 0) continue;
            flags |= j->ifa_flags;
            if (j->ifa_addr == NULL) continue;
            if (j->ifa_addr->sa_family == AF_LINK) data = (struct if_data *)j->ifa_data;
            if (j->ifa_addr->sa_family == AF_INET || j->ifa_addr->sa_family == AF_INET6) {
                [addrs addObject:NUIPStringForSockaddr(j->ifa_addr)];
            }
        }
        [out appendFormat:@"%@  %@  MTU %u",
            name, (flags & IFF_UP) ? @"UP" : @"down",
            data ? data->ifi_mtu : 0];
        if (data && data->ifi_baudrate > 0) {
            [out appendFormat:@"  link rate %llu bit/s (negotiated)", (unsigned long long)data->ifi_baudrate];
        }
        [out appendString:@"\n"];
        for (NSString *a in addrs) [out appendFormat:@"    %@\n", a];
    }
    freeifaddrs(list);
    return [out copy];
}

static const char *NUTCPStateName(int state)
{
    static const char *names[] = {
        "CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED",
        "CLOSE_WAIT", "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT",
    };
    if (state < 0 || state > 10) return "?";
    return names[state];
}

+ (NSString *)socketTableText
{
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) return @"Sockets: process list unavailable.\n";
    pid_t *pids = (pid_t *)calloc((size_t)n + 64, sizeof(pid_t));
    if (pids == NULL) return @"Sockets: out of memory.\n";
    n = proc_listallpids(pids, (int)((n + 64) * (int)sizeof(pid_t)));
    NSMutableString *out = [NSMutableString stringWithString:
        @"Sockets by process (libproc; other users' processes may be hidden by macOS)\n\n"
        "Proto  Local address            Foreign address          State        Process\n"];
    NSUInteger rows = 0;
    const NSUInteger kMaxRows = 8192;
    for (int i = 0; i < n && rows < kMaxRows; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        int fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fdBytes <= 0) continue;
        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)fdBytes);
        if (fds == NULL) continue;
        int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fdBytes);
        if (got <= 0) { free(fds); continue; }
        int fdCount = got / (int)sizeof(struct proc_fdinfo);
        char procName[64] = {0};
        proc_name(pid, procName, sizeof(procName));
        for (int f = 0; f < fdCount && rows < kMaxRows; f++) {
            if (fds[f].proc_fdtype != PROX_FDTYPE_SOCKET) continue;
            struct socket_fdinfo sfi;
            int r = proc_pidfdinfo(pid, fds[f].proc_fd, PROC_PIDFDSOCKETINFO, &sfi, sizeof(sfi));
            if (r != (int)sizeof(sfi)) continue;
            struct socket_info *soi = &sfi.psi;
            if (soi->soi_family != AF_INET && soi->soi_family != AF_INET6) continue;
            BOOL isTCP = (soi->soi_protocol == IPPROTO_TCP);
            const struct in_sockinfo *ini = isTCP ? &soi->soi_proto.pri_tcp.tcpsi_ini
                                                  : &soi->soi_proto.pri_in;
            NSString *laddr, *faddr;
            if (soi->soi_family == AF_INET) {
                struct in_addr la = ini->insi_laddr.ina_46.i46a_addr4;
                struct in_addr fa = ini->insi_faddr.ina_46.i46a_addr4;
                char lb[INET_ADDRSTRLEN], fb[INET_ADDRSTRLEN];
                laddr = @(inet_ntop(AF_INET, &la, lb, sizeof(lb)) ?: "?");
                faddr = @(inet_ntop(AF_INET, &fa, fb, sizeof(fb)) ?: "?");
            } else {
                char lb[INET6_ADDRSTRLEN], fb[INET6_ADDRSTRLEN];
                laddr = @(inet_ntop(AF_INET6, &ini->insi_laddr.ina_6, lb, sizeof(lb)) ?: "?");
                faddr = @(inet_ntop(AF_INET6, &ini->insi_faddr.ina_6, fb, sizeof(fb)) ?: "?");
            }
            NSString *local = [NSString stringWithFormat:@"%@:%d", laddr, ini->insi_lport];
            NSString *foreign = [NSString stringWithFormat:@"%@:%d", faddr, ini->insi_fport];
            NSString *state = isTCP ? @(NUTCPStateName(soi->soi_proto.pri_tcp.tcpsi_state)) : @"—";
            [out appendFormat:@"%-6s %-24s %-24s %-12s %s (%d)\n",
                isTCP ? "tcp" : "udp",
                local.UTF8String, foreign.UTF8String, state.UTF8String,
                procName, (int)pid];
            rows++;
        }
        free(fds);
    }
    free(pids);
    if (rows == 0) [out appendString:@"(no sockets returned)\n"];
    return [out copy];
}

+ (NSDictionary *)defaultRouteInfo
{
    for (NSDictionary *r in NURouteRecords()) {
        if ([r[@"isDefault"] boolValue] && [r[@"gateway"] rangeOfString:@"."].location != NSNotFound) {
            return r;
        }
    }
    for (NSDictionary *r in NURouteRecords()) {
        if ([r[@"isDefault"] boolValue]) return r;
    }
    return nil;
}

+ (uint64_t)negotiatedBaudRateForInterface:(NSString *)interfaceName
{
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0 || list == NULL) return 0;
    uint64_t rate = 0;
    for (struct ifaddrs *ifa = list; ifa != NULL; ifa = ifa->ifa_next) {
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK &&
            strcmp(ifa->ifa_name, interfaceName.UTF8String) == 0) {
            struct if_data *d = (struct if_data *)ifa->ifa_data;
            if (d) rate = d->ifi_baudrate;
            break;
        }
    }
    freeifaddrs(list);
    return rate;
}

@end

#pragma mark - Speed Test

@interface NUSpeedTestEngine ()
@property (nonatomic, strong, nullable) NUPingEngine *ping;
@end

@implementation NUSpeedTestEngine

- (void)cancel
{
    [self.ping cancel];
    self.ping = nil;
}

- (void)deliverSummary:(NSString *)summary error:(NSString *)error
{
    NUSpeedCompletionBlock cb = self.onCompletion;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(summary, error); });
}

- (void)runGatewayLeg
{
    NSDictionary *route = [NUNetstat defaultRouteInfo];
    if (route == nil) {
        [self deliverSummary:@"" error:@"No default route — this Mac has no gateway to test."];
        return;
    }
    NSString *gw = route[@"gateway"];
    NSString *iface = route[@"interface"];
    NSString *err = nil;
    NUTarget *target = [NUTarget targetWithIPLiteral:gw error:&err];
    if (target == nil) {
        [self deliverSummary:@"" error:[NSString stringWithFormat:@"The default gateway (%@) is not a probe target: %@", gw, err ?: @""]];
        return;
    }
    uint64_t baud = [NUNetstat negotiatedBaudRateForInterface:iface];
    __weak typeof(self) weakSelf = self;
    self.ping = [[NUPingEngine alloc] initWithTarget:target count:10 interval:0.5];
    self.ping.onCompletion = ^(NSDictionary *stats, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (self_ == nil) return;
        self_.ping = nil;
        if (error) { [self_ deliverSummary:@"" error:error]; return; }
        NSMutableString *s = [NSMutableString stringWithFormat:
            @"Gateway leg — %@ via %@\nLatency: avg %.1f ms (min %.1f, max %.1f) · loss %.0f%% (%@ of %@ replies)",
            gw, iface,
            [stats[@"avgMs"] doubleValue], [stats[@"minMs"] doubleValue], [stats[@"maxMs"] doubleValue],
            [stats[@"lossPercent"] doubleValue], stats[@"received"], stats[@"sent"]];
        if (baud > 0) {
            double mbps = (double)baud / 1e6;
            [s appendFormat:@"\nNegotiated link rate: %@ — the speed of the local link itself, not a throughput measurement.",
                mbps >= 1000 ? [NSString stringWithFormat:@"%.1f Gbit/s", mbps / 1000.0]
                             : [NSString stringWithFormat:@"%.0f Mbit/s", mbps]];
        }
        [self_ deliverSummary:[s copy] error:nil];
    };
    [self.ping start];
}

- (void)runLANLegWithTarget:(NUTarget *)target
{
    __weak typeof(self) weakSelf = self;
    self.ping = [[NUPingEngine alloc] initWithTarget:target count:10 interval:0.5];
    self.ping.onCompletion = ^(NSDictionary *stats, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (self_ == nil) return;
        self_.ping = nil;
        if (error) { [self_ deliverSummary:@"" error:error]; return; }
        NSString *s = [NSString stringWithFormat:
            @"LAN leg — %@\nLatency: avg %.1f ms (min %.1f, max %.1f) · loss %.0f%% (%@ of %@ replies)",
            [target validatedDescription],
            [stats[@"avgMs"] doubleValue], [stats[@"minMs"] doubleValue], [stats[@"maxMs"] doubleValue],
            [stats[@"lossPercent"] doubleValue], stats[@"received"], stats[@"sent"]];
        [self_ deliverSummary:s error:nil];
    };
    [self.ping start];
}

@end
