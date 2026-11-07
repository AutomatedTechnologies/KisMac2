//
//  NUJournal.m
//  Network Utility (Switchboard V1) — shared local journal. See NUJournal.h.
//

#import "NUJournal.h"

NSString * const NUJournalDidChangeNotification = @"NUJournalDidChangeNotification";

static const NSUInteger kNUMaxJournalEntries = 2000;

@interface NUJournalEntry ()
@property (nonatomic, copy) NSDate *date;
@property (nonatomic) NUJournalEntryKind kind;
@property (nonatomic, copy) NSString *panel;
@property (nonatomic, copy) NSString *targetDescription;
@property (nonatomic, copy) NSString *detail;
@end

@implementation NUJournalEntry

- (NSDictionary *)dictionaryRepresentation
{
    return @{
        @"date": @([self.date timeIntervalSince1970]),
        @"kind": @(self.kind),
        @"panel": self.panel ?: @"",
        @"target": self.targetDescription ?: @"",
        @"detail": self.detail ?: @"",
    };
}

+ (instancetype)entryWithDictionary:(NSDictionary *)dict
{
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NUJournalEntry *e = [[self alloc] init];
    NSNumber *ts = dict[@"date"];
    e.date = ts ? [NSDate dateWithTimeIntervalSince1970:ts.doubleValue] : [NSDate date];
    e.kind = (NUJournalEntryKind)[dict[@"kind"] integerValue];
    e.panel = [dict[@"panel"] isKindOfClass:[NSString class]] ? dict[@"panel"] : @"";
    e.targetDescription = [dict[@"target"] isKindOfClass:[NSString class]] ? dict[@"target"] : @"";
    e.detail = [dict[@"detail"] isKindOfClass:[NSString class]] ? dict[@"detail"] : @"";
    return e;
}

@end

@interface NUJournal ()
@property (nonatomic, copy) NSArray<NUJournalEntry *> *entries;
@property (nonatomic, copy) NSURL *fileURL;
@property (nonatomic) BOOL loaded;
@end

@implementation NUJournal

+ (instancetype)sharedJournal
{
    static NUJournal *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (NSURL *)journalFileURL
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *base = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *dir = [base URLByAppendingPathComponent:@"KisMac2/NetworkUtility" isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"Journal.json"];
}

- (void)loadIfNeeded
{
    if (self.loaded) return;
    self.loaded = YES;
    self.fileURL = [self journalFileURL];
    NSData *data = [NSData dataWithContentsOfURL:self.fileURL];
    NSMutableArray<NUJournalEntry *> *loaded = [NSMutableArray array];
    if (data != nil) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)parsed) {
                NUJournalEntry *e = [NUJournalEntry entryWithDictionary:item];
                if (e) [loaded addObject:e];
            }
        }
    }
    self.entries = [loaded copy];
}

- (NSArray<NUJournalEntry *> *)entries
{
    [self loadIfNeeded];
    return _entries ?: @[];
}

- (void)persist
{
    NSMutableArray *dicts = [NSMutableArray arrayWithCapacity:self.entries.count];
    for (NUJournalEntry *e in self.entries) [dicts addObject:[e dictionaryRepresentation]];
    NSData *data = [NSJSONSerialization dataWithJSONObject:dicts options:NSJSONWritingPrettyPrinted error:nil];
    if (data) [data writeToURL:self.fileURL options:NSDataWritingAtomic error:nil];
}

- (void)addEntryWithKind:(NUJournalEntryKind)kind
                   panel:(NSString *)panel
       targetDescription:(NSString *)targetDescription
                  detail:(NSString *)detail
{
    [self loadIfNeeded];
    NUJournalEntry *e = [[NUJournalEntry alloc] init];
    e.date = [NSDate date];
    e.kind = kind;
    e.panel = panel ?: @"";
    e.targetDescription = targetDescription ?: @"";
    e.detail = detail ?: @"";
    NSMutableArray *next = [NSMutableArray arrayWithObject:e];
    [next addObjectsFromArray:self.entries];
    if (next.count > kNUMaxJournalEntries) {
        [next removeObjectsInRange:NSMakeRange(kNUMaxJournalEntries, next.count - kNUMaxJournalEntries)];
    }
    self.entries = [next copy];
    [self persist];
    [[NSNotificationCenter defaultCenter] postNotificationName:NUJournalDidChangeNotification object:self];
}

- (NSString *)exportText
{
    [self loadIfNeeded];
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    NSMutableString *out = [NSMutableString stringWithString:@"Network Utility — Journal export\n(local record only; never transmitted)\n\n"];
    for (NUJournalEntry *e in self.entries) {
        NSString *kind = e.kind == NUJournalEntryKindDiagnoseRun ? @"diagnose" :
                         e.kind == NUJournalEntryKindManageRead  ? @"manage-read" : @"shell";
        [out appendFormat:@"%@  [%@] %@ — %@ — %@\n",
            [fmt stringFromDate:e.date], kind, e.panel, e.targetDescription, e.detail];
    }
    return [out copy];
}

@end
