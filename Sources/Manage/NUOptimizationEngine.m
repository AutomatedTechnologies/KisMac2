//
//  NUOptimizationEngine.m
//  Workbench (Switchboard V1) — Optimizations: read-only configuration audit.
//  See NUOptimizationEngine.h and Switchboard files/08-OPTIMIZATIONS-DESIGN.md.
//  No I/O, no mutation, no persistence: pure evaluation over inputs.
//

#import "NUOptimizationEngine.h"
#import "NUTarget.h"
#import "NUDriveInventory.h"

@implementation NUOptimizationFinding

- (instancetype)initWithCheckID:(NSString *)checkID
                          title:(NSString *)title
                   currentValue:(NSString *)currentValue
              recommendedValue:(NSString *)recommendedValue
                      rationale:(NSString *)rationale
                       severity:(NUOptimizationSeverity)severity
{
    self = [super init];
    if (self) {
        _checkID = [checkID copy] ?: @"";
        _title = [title copy] ?: @"";
        _currentValue = [currentValue copy] ?: @"";
        _recommendedValue = [recommendedValue copy] ?: @"";
        _rationale = [rationale copy] ?: @"";
        _severity = severity;
    }
    return self;
}

@end

#pragma mark - Payload helpers (same tolerance discipline as NUAirPortClient)

// String form of a payload scalar, or nil when absent/empty. Device-
// controlled text is sanitized by the callers that display it.
static NSString *NUOptString(id value)
{
    if ([value isKindOfClass:[NSString class]]) return [(NSString *)value length] ? value : nil;
    if ([value isKindOfClass:[NSNumber class]]) return [(NSNumber *)value stringValue];
    return nil;
}

static NSString *NUOptClean(id value)
{
    NSString *raw = NUOptString(value);
    if (raw == nil) return nil;
    NSString *clean = [NUTarget sanitizedDisplayString:raw];
    return clean.length ? clean : nil;
}

// All distinct network names the payload reports: the primary name plus
// any 5 GHz name key (a key mentioning both the band and a name).
static NSSet<NSString *> *NUOptReportedSSIDs(NSDictionary *properties)
{
    NSMutableSet<NSString *> *ssids = [NSMutableSet set];
    NSDictionary *wifi = [properties[@"WiFi"] isKindOfClass:[NSDictionary class]] ? properties[@"WiFi"] : properties;
    NSString *primary = NUOptClean(wifi[@"raNm"]);
    if (primary) [ssids addObject:primary];
    for (NSString *key in wifi.allKeys) {
        NSString *lower = key.lowercaseString;
        BOOL bandKey = [lower containsString:@"5g"] || [lower containsString:@"5ghz"];
        BOOL nameKey = [lower containsString:@"nm"] || [lower containsString:@"name"] || [lower containsString:@"ssid"];
        if (bandKey && nameKey) {
            NSString *ssid = NUOptClean(wifi[key]);
            if (ssid) [ssids addObject:ssid];
        }
    }
    return [ssids copy];
}

// Product codes the product map in NUAirPort.m identifies as dual-band
// (simultaneous 2.4 + 5 GHz): 802.11n Gigabit Extreme, Express 2nd gen,
// Time Capsule (802.11ac-era), 802.11ac Extreme.
static BOOL NUOptIsDualBandProduct(NSNumber *code)
{
    if (![code isKindOfClass:[NSNumber class]]) return NO;
    NSInteger v = code.integerValue;
    return v == 105 || v == 115 || v == 119 || v == 120;
}

// Dotted-version comparison: -1 when a < b, 0 equal, 1 when a > b.
// Non-numeric components compare as 0 — a version this cannot parse is
// treated as "not proven behind" by the caller, never as behind.
static NSInteger NUOptCompareVersions(NSString *a, NSString *b)
{
    NSArray<NSString *> *pa = [a componentsSeparatedByString:@"."];
    NSArray<NSString *> *pb = [b componentsSeparatedByString:@"."];
    NSUInteger n = MAX(pa.count, pb.count);
    for (NSUInteger i = 0; i < n; i++) {
        NSInteger va = i < pa.count ? pa[i].integerValue : 0;
        NSInteger vb = i < pb.count ? pb[i].integerValue : 0;
        if (va != vb) return va < vb ? -1 : 1;
    }
    return 0;
}

#pragma mark - Channel congestion (from the Discover scan only)

// Weighted occupancy of a 2.4 GHz candidate channel: networks on nearby
// channels overlap; weight falls linearly to zero five channels away.
static double NUOptCongestion24(NSArray<NSDictionary *> *scan, NSInteger candidate)
{
    double score = 0;
    for (NSDictionary *net in scan) {
        NSInteger ch = [net[@"channel"] integerValue];
        if (ch < 1 || ch > 14) continue; // not a 2.4 GHz observation
        double overlap = 1.0 - (double)labs(ch - candidate) / 5.0;
        if (overlap > 0) score += [net[@"signal"] doubleValue] * overlap;
    }
    return score;
}

// Occupancy of a 5 GHz channel: same-channel only (channels are wide
// and non-overlapping at this granularity).
static double NUOptCongestion5(NSArray<NSDictionary *> *scan, NSInteger candidate)
{
    double score = 0;
    for (NSDictionary *net in scan) {
        if ([net[@"channel"] integerValue] == candidate) {
            score += [net[@"signal"] doubleValue];
        }
    }
    return score;
}

@implementation NUOptimizationEngine

+ (NSArray<NUOptimizationFinding *> *)findingsFromProperties:(NSDictionary *)properties
                                                scanNetworks:(NSArray<NSDictionary *> *)scanNetworks
                                                     clients:(NSArray<NSDictionary *> *)clients
{
    if (![properties isKindOfClass:[NSDictionary class]]) return @[];
    NSArray<NSDictionary *> *scan = [scanNetworks isKindOfClass:[NSArray class]] ? scanNetworks : @[];
    NSMutableArray<NUOptimizationFinding *> *findings = [NSMutableArray array];
    NSDictionary *wifi = [properties[@"WiFi"] isKindOfClass:[NSDictionary class]] ? properties[@"WiFi"] : properties;

    // -- Check 1: separate 5 GHz network name --------------------------
    // Dual-band station reporting a single network name: both bands
    // share one name, so band steering decides for the client — and a
    // stationary 5 GHz-capable device can end up parked on 2.4 GHz.
    if (NUOptIsDualBandProduct(properties[@"syAP"])) {
        NSSet<NSString *> *ssids = NUOptReportedSSIDs(properties);
        if (ssids.count == 1) {
            NSString *name = ssids.anyObject;
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"band-name-separation"
                          title:@"5 GHz network name"
                   currentValue:[NSString stringWithFormat:@"Same name as 2.4 GHz (%@)", name]
              recommendedValue:[NSString stringWithFormat:@"A separate name, e.g. %@-5GHz", name]
                      rationale:@"One shared name lets devices drift onto the slower 2.4 GHz band; a separate 5 GHz name lets you put fast devices there on purpose."
                       severity:NUOptimizationSeverityRecommendation]];
        }
    }

    // -- Check 2a: 2.4 GHz channel vs measured congestion --------------
    NSNumber *channel24 = nil;
    if ([properties[@"bsRC"] isKindOfClass:[NSNumber class]]) channel24 = properties[@"bsRC"];
    if (channel24 != nil && scan.count > 0) {
        NSInteger current = channel24.integerValue;
        if (current == 1000) {
            // 1000 is the payload's Automatic marker (NUAirPortClient).
            NSInteger best = 1; double bestScore = NUOptCongestion24(scan, 1);
            for (NSInteger c = 6; c <= 11; c += 5) {
                double s = NUOptCongestion24(scan, c);
                if (s < bestScore) { bestScore = s; best = c; }
            }
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"channel-2.4-automatic"
                          title:@"2.4 GHz channel"
                   currentValue:@"Automatic (chosen at startup)"
              recommendedValue:[NSString stringWithFormat:@"Channel %ld, from today's survey", (long)best]
                      rationale:@"Automatic picks once when the station starts and never looks again; the survey around you now points to a clearer channel."
                       severity:NUOptimizationSeverityAdvisory]];
        } else if (current >= 1 && current <= 14) {
            NSInteger best = current; double bestScore = NUOptCongestion24(scan, current);
            for (NSInteger c = 1; c <= 11; c += 5) {
                double s = NUOptCongestion24(scan, c);
                if (s < bestScore) { bestScore = s; best = c; }
            }
            double currentScore = NUOptCongestion24(scan, current);
            BOOL nonStandard = !(current == 1 || current == 6 || current == 11);
            if (best != current && (nonStandard || currentScore > bestScore * 1.5)) {
                [findings addObject:[[NUOptimizationFinding alloc]
                    initWithCheckID:@"channel-2.4"
                              title:@"2.4 GHz channel"
                       currentValue:[NSString stringWithFormat:@"Channel %ld", (long)current]
                  recommendedValue:[NSString stringWithFormat:@"Channel %ld", (long)best]
                          rationale:@"Channels 1, 6 and 11 are the only 2.4 GHz channels that do not overlap each other; the survey shows the recommended one carrying the least traffic."
                           severity:NUOptimizationSeverityRecommendation]];
            }
        }
    }

    // -- Check 2b: 5 GHz channel vs measured congestion ----------------
    // The payload names the 5 GHz channel only on stations that report
    // it separately; the field is located by shape (a band-marked
    // channel key), never assumed. Absent field or absent 5 GHz scan
    // data, no finding.
    NSNumber *channel5 = nil;
    for (NSString *key in wifi.allKeys) {
        NSString *lower = key.lowercaseString;
        BOOL bandKey = [lower containsString:@"5g"] || [lower containsString:@"5ghz"];
        BOOL channelKey = [lower containsString:@"ch"] || [lower containsString:@"channel"];
        if (bandKey && channelKey && [wifi[key] isKindOfClass:[NSNumber class]]) {
            channel5 = wifi[key];
            break;
        }
    }
    BOOL scanHas5 = NO;
    for (NSDictionary *net in scan) {
        NSInteger ch = [net[@"channel"] integerValue];
        if (ch >= 32 && ch <= 177) { scanHas5 = YES; break; }
    }
    if (channel5 != nil && scanHas5) {
        NSInteger current = channel5.integerValue;
        NSArray<NSNumber *> *candidates = @[@36, @44, @149, @157];
        NSInteger best = current;
        double bestScore = NUOptCongestion5(scan, current);
        for (NSNumber *c in candidates) {
            double s = NUOptCongestion5(scan, c.integerValue);
            if (s < bestScore) { bestScore = s; best = c.integerValue; }
        }
        if (best != current && NUOptCongestion5(scan, current) > bestScore) {
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"channel-5"
                          title:@"5 GHz channel"
                   currentValue:[NSString stringWithFormat:@"Channel %ld", (long)current]
              recommendedValue:[NSString stringWithFormat:@"Channel %ld", (long)best]
                      rationale:@"5 GHz channels do not overlap, so a channel nobody nearby is using is free airtime; the survey shows the recommended one unused or quietest."
                       severity:NUOptimizationSeverityRecommendation]];
        }
    }

    // -- Check 3: DNS resolvers ----------------------------------------
    NSMutableArray<NSString *> *dns = [NSMutableArray array];
    for (NSString *k in @[@"waD1", @"waD2", @"waD3"]) {
        NSString *v = NUOptString(properties[k]);
        if (v) [dns addObject:v];
    }
    NSString *gateway = NUOptString(properties[@"waRA"]);
    BOOL fastPublic = NO;
    for (NSString *addr in dns) {
        if ([addr isEqualToString:@"1.1.1.1"] || [addr isEqualToString:@"8.8.8.8"] ||
            [addr isEqualToString:@"1.0.0.1"] || [addr isEqualToString:@"8.8.4.4"]) fastPublic = YES;
    }
    if (!fastPublic) {
        BOOL ispDefault = dns.count == 0 || (gateway != nil && dns.count == 1 && [dns[0] isEqualToString:gateway]);
        if (ispDefault) {
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"dns-resolvers"
                          title:@"DNS servers"
                   currentValue:dns.count ? [dns componentsJoinedByString:@", "] : @"Assigned by the internet provider"
              recommendedValue:@"1.1.1.1 and 8.8.8.8"
                      rationale:@"Every page and app starts with a DNS lookup; fast public resolvers usually answer sooner than the provider's default servers."
                       severity:NUOptimizationSeverityAdvisory]];
        }
    }

    // -- Check 4: firmware currency ------------------------------------
    // Latest known firmware per model, from the advisory set of record.
    // Only models whose latest version is on record are checked — the
    // engine never guesses a latest version for a model it does not know.
    NSString *firmware = NUOptString(properties[@"syVs"]);
    NSNumber *product = [properties[@"syAP"] isKindOfClass:[NSNumber class]] ? properties[@"syAP"] : nil;
    if (firmware != nil && product != nil && product.integerValue == 120) {
        if (NUOptCompareVersions(firmware, @"7.9.1") < 0) {
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"firmware-currency"
                          title:@"Firmware"
                   currentValue:firmware
              recommendedValue:@"7.9.1 (the last release for this model)"
                      rationale:@"7.9.1 is the final firmware Apple released for this base station; it carries the last security fixes the model will receive."
                       severity:NUOptimizationSeverityAdvisory]];
        }
    }

    // -- Check 5: multicast rate ---------------------------------------
    // Read whatever multicast-rate field the payload carries; absent
    // field, no finding. "Low" (or the lowest numeric step) holds
    // multicast to the slowest rate, which costs airtime on every
    // multicast frame the network sends.
    id multicast = nil;
    for (NSString *key in properties.allKeys) {
        if ([key.lowercaseString containsString:@"multicast"]) { multicast = properties[key]; break; }
    }
    if (multicast == nil) {
        for (NSString *key in wifi.allKeys) {
            if ([key.lowercaseString containsString:@"multicast"]) { multicast = wifi[key]; break; }
        }
    }
    if (multicast != nil) {
        BOOL atLow = NO;
        if ([multicast isKindOfClass:[NSNumber class]]) atLow = [multicast integerValue] <= 0;
        else if ([multicast isKindOfClass:[NSString class]]) atLow = [[(NSString *)multicast lowercaseString] isEqualToString:@"low"];
        if (atLow) {
            [findings addObject:[[NUOptimizationFinding alloc]
                initWithCheckID:@"multicast-rate"
                          title:@"Multicast rate"
                   currentValue:@"Low"
              recommendedValue:@"One step above Low"
                      rationale:@"At Low, multicast traffic (screen sharing, discovery) is sent at the slowest rate and uses more airtime; raising it one step frees the band — but a device at the far edge of coverage may lose multicast first, so test edge rooms after changing it."
                       severity:NUOptimizationSeverityAdvisory]];
        }
    }

    // -- Check 6a: guest network load note (informational) -------------
    BOOL guestOn = NO;
    for (NSString *key in properties.allKeys) {
        if ([key.lowercaseString containsString:@"guest"]) {
            id v = properties[key];
            if ([v isKindOfClass:[NSNumber class]] && [v boolValue]) guestOn = YES;
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) guestOn = YES;
        }
    }
    if (guestOn) {
        [findings addObject:[[NUOptimizationFinding alloc]
            initWithCheckID:@"load-guest-network"
                      title:@"Guest network"
               currentValue:@"On"
          recommendedValue:@"No change recommended"
                  rationale:@"The guest network adds its own beacons and traffic to the same radios; worth knowing it is on, and worth turning off only if nobody uses it."
                   severity:NUOptimizationSeverityInformational]];
    }

    // -- Check 6b: attached-drive backup load note (informational) ----
    NSArray<NUDriveInfo *> *drives = [NUDriveInventory drivesFromProperties:properties];
    if (drives.count > 0) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NUDriveInfo *d in drives) [names addObject:d.displayName];
        [findings addObject:[[NUOptimizationFinding alloc]
            initWithCheckID:@"load-attached-disk"
                      title:@"Attached storage"
               currentValue:[names componentsJoinedByString:@", "]
          recommendedValue:@"No change recommended"
                  rationale:@"Network backups to an attached disk share the same radios and processor as everything else; a slowdown during a backup window is the disk working, not a fault."
                   severity:NUOptimizationSeverityInformational]];
    }

    // -- Check 7: wired-offload candidates (informational) -------------
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (NSDictionary *client in clients ?: @[]) {
        if ([client[@"stationary"] boolValue] && [client[@"highTraffic"] boolValue]) {
            NSString *name = NUOptClean(client[@"name"]) ?: @"Unnamed device";
            [candidates addObject:name];
        }
    }
    if (candidates.count > 0) {
        [findings addObject:[[NUOptimizationFinding alloc]
            initWithCheckID:@"wired-offload"
                      title:@"Devices that could go wired"
               currentValue:[candidates componentsJoinedByString:@", "]
          recommendedValue:@"Ethernet, where a cable run is practical"
                  rationale:@"These devices never move and use the most airtime; wiring even one of them frees the wireless band for everything that has to stay wireless."
                   severity:NUOptimizationSeverityInformational]];
    }

    // Order: severity first, stable within a severity (checks were
    // appended in advisory-set order).
    NSComparator bySeverity = ^NSComparisonResult(NUOptimizationFinding *a, NUOptimizationFinding *b) {
        if (a.severity != b.severity) return a.severity < b.severity ? NSOrderedAscending : NSOrderedDescending;
        return NSOrderedSame;
    };
    return [findings sortedArrayWithOptions:NSSortStable usingComparator:bySeverity];
}

+ (NSArray<NSDictionary *> *)rowsFromFindings:(NSArray<NUOptimizationFinding *> *)findings
{
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NUOptimizationFinding *f in findings) {
        NSString *value = [NSString stringWithFormat:@"%@ → %@ — %@",
                           f.currentValue, f.recommendedValue, f.rationale];
        [rows addObject:@{@"item": f.title, @"value": value}];
    }
    return [rows copy];
}

+ (NSString *)journalSummaryFromFindings:(NSArray<NUOptimizationFinding *> *)findings
{
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:@"Optimizations audit — %lu finding(s)", (unsigned long)findings.count]];
    for (NUOptimizationFinding *f in findings) {
        [lines addObject:[NSString stringWithFormat:@"%@: current %@; recommended %@",
                          f.title, f.currentValue, f.recommendedValue]];
    }
    return [lines componentsJoinedByString:@"\n"];
}

@end
