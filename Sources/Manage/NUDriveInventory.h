//
//  NUDriveInventory.h
//  Workbench (Switchboard V1) — Manage: attached-drive inventory (READ).
//
//  Design: Switchboard files/06-DRIVE-MANAGEMENT-DESIGN.md (2026-11-07).
//
//  This module is the transport-independent view model for drives attached
//  to a managed target: internal disks and USB storage on AirPort Time
//  Capsules today (parsed from the ACP "MaSt" master-status property of the
//  same authenticated read session NUAirPortClient already performs), and
//  Merlin/USB targets later through the same model (Switchboard
//  files/07-MERLIN-INTEGRATION-EXPLORATION.md).
//
//  READ ONLY, and narrower than read-only: this file performs no I/O at
//  all. It transforms a property payload the client already holds into
//  panel rows. There is no format, no share change, no mount/unmount, no
//  write path of any kind — drive mutation is designed and gated in the
//  design doc above and does not exist in code.
//
//  Honesty rules (design doc §3):
//  - A field the station did not report is absent from the model, never
//    estimated, interpolated, or carried over from a previous read.
//  - A numeric field whose unit is not known to be bytes is NOT rescaled
//    by a guess: values below the plausible-byte floor are surfaced raw
//    in rawSummary instead of being presented as a capacity.
//  - Drive and volume names are device-controlled strings: every string
//    that reaches the model is passed through TargetKit sanitization
//    (spec §6 lesson 3 — bounded strings on all network data).
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NUDriveInfo : NSObject
// Volume/disk name as reported by the target (sanitized). Always present.
@property (nonatomic, copy, readonly) NSString *displayName;
// Byte counts, only when the payload reported them in bytes (see header).
@property (nonatomic, copy, readonly, nullable) NSNumber *capacityBytes;
@property (nonatomic, copy, readonly, nullable) NSNumber *freeBytes;
// Filesystem/format name as reported (sanitized), e.g. "HFS+", "APFS".
@property (nonatomic, copy, readonly, nullable) NSString *formatName;
// Station-reported status/health string (sanitized), passed through as
// reported — this module does not reinterpret device health vocabulary.
@property (nonatomic, copy, readonly, nullable) NSString *statusName;
// Fallback: the entry's scalar rendering when it carried no structured
// fields (the pre-tranche opaque behavior, preserved for unknown shapes).
@property (nonatomic, copy, readonly, nullable) NSString *rawSummary;
- (instancetype)initWithDisplayName:(NSString *)name
                      capacityBytes:(nullable NSNumber *)capacityBytes
                          freeBytes:(nullable NSNumber *)freeBytes
                         formatName:(nullable NSString *)formatName
                         statusName:(nullable NSString *)statusName
                         rawSummary:(nullable NSString *)rawSummary;
@end

@interface NUDriveInventory : NSObject
// Parse the drive inventory out of a full ACP property payload (the
// "MaSt" master-status property). Returns an empty array when the payload
// carries no drive data — the caller then falls back to its legacy
// rendering. Tolerates the shapes the public ACP references document:
// a dictionary keyed by drive name (values: per-drive dictionaries or
// scalars), or an array of per-drive dictionaries carrying a name key.
+ (NSArray<NUDriveInfo *> *)drivesFromProperties:(NSDictionary *)properties;
// Panel rows (item/value) for the Manage Disks section: one summary row
// per drive, plus a status row per drive that reported one.
+ (NSArray<NSDictionary *> *)rowsFromDrives:(NSArray<NUDriveInfo *> *)drives;
// "238.4 GB" decimal byte formatting (NSByteCountFormatter, file style).
// Returns nil for nil input.
+ (nullable NSString *)humanBytes:(nullable NSNumber *)bytes;
@end

NS_ASSUME_NONNULL_END
