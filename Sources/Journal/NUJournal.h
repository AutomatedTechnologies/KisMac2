//
//  NUJournal.h
//  Network Utility (Switchboard V1) — shared local journal.
//
//  One timeline for the whole utility (KisMac 07-V2-UNIFIED-SPEC.md §5.3):
//  Diagnose run records in this build; Manage change entries arrive with the
//  gated write tranche. The journal is a local file in Application Support.
//  It is never transmitted anywhere — there is no network code in this class
//  and no telemetry in this product.
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const NUJournalDidChangeNotification;

typedef NS_ENUM(NSInteger, NUJournalEntryKind) {
    NUJournalEntryKindDiagnoseRun = 0,
    NUJournalEntryKindManageRead  = 1,
    NUJournalEntryKindShellEvent  = 2,
};

@interface NUJournalEntry : NSObject
@property (nonatomic, copy, readonly) NSDate *date;
@property (nonatomic, readonly) NUJournalEntryKind kind;
@property (nonatomic, copy, readonly) NSString *panel;            // e.g. "Ping", "Base Stations"
@property (nonatomic, copy, readonly) NSString *targetDescription; // validated form only (TargetKit)
@property (nonatomic, copy, readonly) NSString *detail;
- (NSDictionary *)dictionaryRepresentation;
+ (nullable instancetype)entryWithDictionary:(NSDictionary *)dict;
@end

@interface NUJournal : NSObject

+ (instancetype)sharedJournal;

// Newest first. Loaded from disk at first access.
@property (nonatomic, copy, readonly) NSArray<NUJournalEntry *> *entries;

// Records an entry and persists the journal. targetDescription must already
// be the validated form (NUTarget validatedDescription) — the journal stores
// no raw user input, so log injection through a crafted name is impossible.
- (void)addEntryWithKind:(NUJournalEntryKind)kind
                   panel:(NSString *)panel
       targetDescription:(NSString *)targetDescription
                  detail:(NSString *)detail;

// Human-readable export (the UI's Export button writes this to a file the
// user chooses). Returns nil on failure.
- (nullable NSString *)exportText;

@end

NS_ASSUME_NONNULL_END
