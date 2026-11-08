//
//  NUDriveInventory.m
//  Workbench (Switchboard V1) — Manage: attached-drive inventory (READ).
//  See NUDriveInventory.h. No I/O, no mutation, no persistence.
//

#import "NUDriveInventory.h"
#import "NUTarget.h"

@implementation NUDriveInfo

- (instancetype)initWithDisplayName:(NSString *)name
                      capacityBytes:(NSNumber *)capacityBytes
                          freeBytes:(NSNumber *)freeBytes
                         formatName:(NSString *)formatName
                         statusName:(NSString *)statusName
                         rawSummary:(NSString *)rawSummary
{
    self = [super init];
    if (self) {
        _displayName = [name copy] ?: @"Drive";
        _capacityBytes = [capacityBytes copy];
        _freeBytes = [freeBytes copy];
        _formatName = [formatName copy];
        _statusName = [statusName copy];
        _rawSummary = [rawSummary copy];
    }
    return self;
}

@end

// A reported number is treated as a byte count only at or above this floor.
// Real attached storage is never smaller; a smaller value means the unit
// is something else (sectors, KB, a code) and the number is shown raw
// rather than rescaled by a guess (design doc §3, honesty rules).
static const long long kNUDrivePlausibleByteFloor = 1000000LL;

// First non-nil value among candidate keys, or nil.
static id NUDriveValueForKeys(NSDictionary *dict, NSArray<NSString *> *keys)
{
    for (NSString *key in keys) {
        id value = dict[key];
        if (value != nil && value != [NSNull null]) return value;
    }
    return nil;
}

// Coerce a payload value to a number without inventing one: NSNumber
// passes through; an NSString of digits (optionally grouped/decimal) is
// parsed; anything else yields nil.
static NSNumber *NUDriveNumber(id value)
{
    if ([value isKindOfClass:[NSNumber class]]) return value;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *cleaned = [(NSString *)value stringByReplacingOccurrencesOfString:@"," withString:@""];
        NSScanner *scanner = [NSScanner scannerWithString:cleaned];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) {
            return @(parsed);
        }
    }
    return nil;
}

static NSString *NUDriveString(id value)
{
    NSString *raw = nil;
    if ([value isKindOfClass:[NSString class]]) raw = value;
    else if ([value isKindOfClass:[NSNumber class]]) raw = [(NSNumber *)value stringValue];
    if (raw == nil || raw.length == 0) return nil;
    NSString *clean = [NUTarget sanitizedDisplayString:raw];
    return clean.length ? clean : nil;
}

// Byte interpretation per the honesty rules: nil unless the value is a
// number at or above the plausible-byte floor.
static NSNumber *NUDriveBytes(id value)
{
    NSNumber *number = NUDriveNumber(value);
    if (number == nil) return nil;
    if ([number longLongValue] < kNUDrivePlausibleByteFloor) return nil;
    return number;
}

static NUDriveInfo *NUDriveInfoFromEntry(NSString *fallbackName, id entry)
{
    NSString *name = NUDriveString(fallbackName) ?: @"Drive";
    if ([entry isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = entry;
        NSString *reportedName = NUDriveString(NUDriveValueForKeys(dict, @[@"name", @"volume", @"label"]));
        if (reportedName) name = reportedName;
        NSNumber *capacity = NUDriveBytes(NUDriveValueForKeys(dict, @[@"capacity", @"totalBytes", @"total", @"size", @"cap"]));
        NSNumber *free = NUDriveBytes(NUDriveValueForKeys(dict, @[@"freeBytes", @"free", @"available", @"avail"]));
        NSString *format = NUDriveString(NUDriveValueForKeys(dict, @[@"format", @"fileSystem", @"fsType", @"fs"]));
        NSString *status = NUDriveString(NUDriveValueForKeys(dict, @[@"status", @"health", @"state"]));
        NSString *raw = nil;
        if (capacity == nil && free == nil && format == nil && status == nil) {
            // Structured entry, but none of the fields this inventory
            // understands: keep the entry visible, opaquely, rather than
            // dropping a drive the station reported.
            raw = [NSString stringWithFormat:@"(%lu entries)", (unsigned long)dict.count];
        }
        return [[NUDriveInfo alloc] initWithDisplayName:name
                                          capacityBytes:capacity
                                              freeBytes:free
                                             formatName:format
                                             statusName:status
                                             rawSummary:raw];
    }
    // Scalar entry (string/number): the pre-tranche opaque rendering.
    NSString *raw = NUDriveString(entry);
    if (raw == nil) return nil;
    return [[NUDriveInfo alloc] initWithDisplayName:name
                                      capacityBytes:nil
                                          freeBytes:nil
                                         formatName:nil
                                         statusName:nil
                                         rawSummary:raw];
}

@implementation NUDriveInventory

+ (NSArray<NUDriveInfo *> *)drivesFromProperties:(NSDictionary *)properties
{
    if (![properties isKindOfClass:[NSDictionary class]]) return @[];
    id master = properties[@"MaSt"];
    NSMutableArray<NUDriveInfo *> *drives = [NSMutableArray array];
    if ([master isKindOfClass:[NSDictionary class]]) {
        NSDictionary *byName = master;
        for (NSString *key in [byName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NUDriveInfo *info = NUDriveInfoFromEntry(key, byName[key]);
            if (info) [drives addObject:info];
        }
    } else if ([master isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)master) {
            NUDriveInfo *info = NUDriveInfoFromEntry(nil, entry);
            if (info) [drives addObject:info];
        }
    }
    return [drives copy];
}

+ (NSString *)humanBytes:(NSNumber *)bytes
{
    if (bytes == nil) return nil;
    return [NSByteCountFormatter stringFromByteCount:[bytes longLongValue]
                                          countStyle:NSByteCountFormatterCountStyleFile];
}

+ (NSArray<NSDictionary *> *)rowsFromDrives:(NSArray<NUDriveInfo *> *)drives
{
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (NUDriveInfo *drive in drives) {
        NSMutableArray<NSString *> *parts = [NSMutableArray array];
        NSString *capacity = [self humanBytes:drive.capacityBytes];
        NSString *free = [self humanBytes:drive.freeBytes];
        if (capacity) [parts addObject:capacity];
        if (free) [parts addObject:[NSString stringWithFormat:@"%@ free", free]];
        if (drive.formatName) [parts addObject:drive.formatName];
        NSString *summary = parts.count ? [parts componentsJoinedByString:@" · "] : drive.rawSummary;
        if (summary) {
            [rows addObject:@{@"item": drive.displayName, @"value": summary}];
        }
        if (drive.statusName) {
            [rows addObject:@{@"item": [NSString stringWithFormat:@"%@ — status", drive.displayName],
                              @"value": drive.statusName}];
        }
    }
    return [rows copy];
}

@end
