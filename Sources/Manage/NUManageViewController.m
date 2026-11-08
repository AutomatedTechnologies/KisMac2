//
//  NUManageViewController.m
//  Network Utility (Switchboard V1) — Manage (READ) panel UI. See header.
//

#import "NUManageViewController.h"
#import "NUAirPort.h"
#import "NUJournal.h"
#import "NUOptimizationEngine.h"

@interface NUManageViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NUAirPortBrowser *browser;
@property (nonatomic, strong) NSTableView *stationTable;
@property (nonatomic, strong) NSTableView *configTable;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *readButton;
@property (nonatomic, strong) NSButton *auditButton;
@property (nonatomic, copy) NSArray<NSDictionary *> *sections; // flattened below
@property (nonatomic, copy) NSArray<NSDictionary *> *flatRows; // @{section,item,value}
@property (nonatomic, strong, nullable) NUAirPortStation *selectedStation;
@property (nonatomic) BOOL reading;
// The last completed read, kept so the Optimizations audit can re-run
// on demand ("Run audit", files/08 §4) against a fresh survey without
// opening a new station session. Displayable properties only — the
// client layer has already excluded every password-typed value, so no
// credential can reach the audit engine or the journal through here.
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *lastSections;
@property (nonatomic, copy, nullable) NSDictionary *lastProperties;
@property (nonatomic, copy, nullable) NSString *lastTargetDescription;
@end

@implementation NUManageViewController

- (void)loadView
{
    // Layout note (owner UAT 2026-11-07 20:59): the frames below are the
    // design size; the shell stretches this view to the content area at
    // any window size, so every subview carries an autoresizing mask —
    // headers/status pinned to the top (flexible BOTTOM margin), the two
    // tables flexible in the directions they can grow, the buttons and
    // the note pinned to the bottom (fixed bottom margin, the default).
    // Without masks the whole layout stayed a fixed 760x520 block
    // anchored bottom-left and the panel read as layered/offset.
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 520)];

    NSTextField *listHeader = [NSTextField labelWithString:@"BASE STATIONS"];
    listHeader.frame = NSMakeRect(16, 492, 200, 16);
    listHeader.autoresizingMask = NSViewMinYMargin;
    listHeader.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    listHeader.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1]; // SDS muted
    [root addSubview:listHeader];

    NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 96, 216, 388)];
    listScroll.hasVerticalScroller = YES;
    listScroll.borderType = NSBezelBorder;
    listScroll.autoresizingMask = NSViewHeightSizable;
    self.stationTable = [[NSTableView alloc] initWithFrame:listScroll.contentView.bounds];
    NSTableColumn *nameCol = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    nameCol.title = @"Station";
    nameCol.width = 200;
    nameCol.resizingMask = NSTableColumnAutoresizingMask;
    [self.stationTable addTableColumn:nameCol];
    self.stationTable.dataSource = self;
    self.stationTable.delegate = self;
    self.stationTable.rowHeight = 30;
    listScroll.documentView = self.stationTable;
    [root addSubview:listScroll];

    NSButton *addButton = [NSButton buttonWithTitle:@"Add by IP…" target:self action:@selector(addByIP:)];
    addButton.frame = NSMakeRect(16, 60, 104, 28);
    addButton.bezelStyle = NSBezelStyleRounded;
    [root addSubview:addButton];

    self.readButton = [NSButton buttonWithTitle:@"Read" target:self action:@selector(readPressed:)];
    self.readButton.frame = NSMakeRect(128, 60, 104, 28);
    self.readButton.bezelStyle = NSBezelStyleRounded;
    self.readButton.enabled = NO;
    [root addSubview:self.readButton];

    NSTextField *readOnlyNote = [NSTextField wrappingLabelWithString:@"Read-only. This build cannot change a base station — it has no configuration write path. The station password is asked per session and held in memory only."];
    readOnlyNote.frame = NSMakeRect(16, 8, 216, 48);
    readOnlyNote.font = [NSFont systemFontOfSize:11];
    readOnlyNote.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1];
    [root addSubview:readOnlyNote];

    NSScrollView *configScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(248, 48, 496, 436)];
    configScroll.hasVerticalScroller = YES;
    configScroll.borderType = NSBezelBorder;
    configScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.configTable = [[NSTableView alloc] initWithFrame:configScroll.contentView.bounds];
    NSTableColumn *itemCol = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    itemCol.title = @"Item";
    itemCol.width = 180;
    NSTableColumn *valueCol = [[NSTableColumn alloc] initWithIdentifier:@"value"];
    valueCol.title = @"Value";
    valueCol.width = 300;
    valueCol.resizingMask = NSTableColumnAutoresizingMask;
    [self.configTable addTableColumn:itemCol];
    [self.configTable addTableColumn:valueCol];
    self.configTable.dataSource = self;
    self.configTable.delegate = self;
    self.configTable.usesAlternatingRowBackgroundColors = YES;
    configScroll.documentView = self.configTable;
    [root addSubview:configScroll];

    self.statusLabel = [NSTextField wrappingLabelWithString:@"Looking for base stations on the local network (Bonjour)…"];
    self.statusLabel.frame = NSMakeRect(248, 492, 400, 16);
    self.statusLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.statusLabel.font = [NSFont systemFontOfSize:12];
    self.statusLabel.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1];
    [root addSubview:self.statusLabel];

    // Optimizations audit (files/08 §4): re-runs the read-only audit
    // against the last completed read and the current survey. Enabled
    // only after a read — before one, the panel's empty state is the
    // status line's prompt to select a station and Read. The audit
    // has no apply control, here or anywhere (files/08 §1/§4).
    self.auditButton = [NSButton buttonWithTitle:@"Run audit" target:self action:@selector(auditPressed:)];
    self.auditButton.frame = NSMakeRect(656, 488, 88, 24);
    self.auditButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    self.auditButton.bezelStyle = NSBezelStyleRounded;
    self.auditButton.enabled = NO;
    self.auditButton.toolTip = @"Run the Optimizations audit on the last configuration read, using the current network survey.";
    [root addSubview:self.auditButton];

    self.view = root;

    self.browser = [[NUAirPortBrowser alloc] init];
    __weak typeof(self) weakSelf = self;
    self.browser.onChange = ^{ [weakSelf.stationTable reloadData]; };
    [self.browser startBrowsing];
}

- (void)dealloc
{
    [self.browser stopBrowsing];
}

- (BOOL)classroomMode
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"NUClassroomMode"];
}

#pragma mark - Station table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    if (tableView == self.stationTable) return (NSInteger)self.browser.stations.count;
    return (NSInteger)self.flatRows.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    if (tableView == self.stationTable) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:@"station" owner:self];
        if (cell == nil) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 30)];
            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.frame = NSMakeRect(4, 6, 192, 18);
            tf.font = [NSFont systemFontOfSize:12];
            [cell addSubview:tf];
            cell.textField = tf;
            cell.identifier = @"station";
        }
        NUAirPortStation *st = self.browser.stations[(NSUInteger)row];
        cell.textField.stringValue = st.ipAddress.length
            ? [NSString stringWithFormat:@"%@ · %@", st.displayName, st.ipAddress]
            : st.displayName;
        return cell;
    }
    NSDictionary *r = self.flatRows[(NSUInteger)row];
    BOOL isHeader = [r[@"header"] boolValue];
    NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 18)];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(2, 1, tableColumn.width - 4, 16);
        tf.font = [NSFont systemFontOfSize:12];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:tf];
        cell.textField = tf;
        cell.identifier = tableColumn.identifier;
    }
    if ([tableColumn.identifier isEqualToString:@"item"]) {
        cell.textField.stringValue = isHeader ? r[@"section"] : r[@"item"];
        cell.textField.font = isHeader ? [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold]
                                       : [NSFont systemFontOfSize:12];
    } else {
        cell.textField.stringValue = isHeader ? @"" : (r[@"value"] ?: @"");
        cell.textField.font = [NSFont systemFontOfSize:12];
    }
    return cell;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
    if (tableView == self.configTable) return [self.flatRows[(NSUInteger)row][@"header"] boolValue];
    return NO;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    if (notification.object != self.stationTable) return;
    NSInteger row = self.stationTable.selectedRow;
    self.selectedStation = (row >= 0) ? self.browser.stations[(NSUInteger)row] : nil;
    self.readButton.enabled = (self.selectedStation != nil && !self.reading);
    if (self.onSelectTarget) {
        NUTarget *t = nil;
        if (self.selectedStation.ipAddress.length) {
            t = [NUTarget targetWithBaseStationName:self.selectedStation.displayName
                                        ipLiteral:self.selectedStation.ipAddress
                                        modelHint:self.selectedStation.modelHint
                                             error:NULL];
        }
        self.onSelectTarget(t);
    }
}

#pragma mark - Actions

- (void)addByIP:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add a base station by IP address";
    alert.informativeText = @"Enter the station's IPv4 address on this network. The address is validated before anything connects to it.";
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    field.placeholderString = @"e.g. 10.0.1.1";
    alert.accessoryView = field;
    [alert addButtonWithTitle:@"Add"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    NSString *input = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *error = nil;
    NUTarget *target = [NUTarget targetWithIPLiteral:input error:&error];
    if (target == nil) {
        self.statusLabel.stringValue = error ?: @"That is not a valid IPv4 address.";
        NSBeep();
        return;
    }
    [self.browser addStationWithTarget:target];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Added %@ — select it, then Read.", input];
}

- (void)readPressed:(id)sender
{
    NUAirPortStation *station = self.selectedStation;
    if (station == nil || self.reading) return;
    NSString *password = nil;
    if (![self classroomMode]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Base station password for “%@”", station.displayName];
        alert.informativeText = @"Asked once per session and held in memory only — never stored, logged, or journaled. Leave empty to try without a password.";
        NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
        alert.accessoryView = field;
        [alert addButtonWithTitle:@"Read"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
        password = field.stringValue.length ? field.stringValue : nil;
    } else {
        self.statusLabel.stringValue = @"Classroom mode: reading without a credential prompt.";
    }
    [self fetchStation:station password:password];
}

- (void)fetchStation:(NUAirPortStation *)station password:(NSString *)password
{
    self.reading = YES;
    self.readButton.enabled = NO;
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Reading configuration from %@…", station.displayName];
    __weak typeof(self) weakSelf = self;
    [NUAirPortClient fetchConfigurationForStation:station password:password
                                       completion:^(NSArray<NSDictionary *> *sections,
                                                    NSDictionary *rawProperties,
                                                    NSString *error) {
        typeof(self) self_ = weakSelf;
        self_.reading = NO;
        self_.readButton.enabled = (self_.selectedStation != nil);
        if (error) {
            self_.statusLabel.stringValue = error;
            return;
        }
        NSString *targetDesc = station.ipAddress.length
            ? [[NUTarget targetWithBaseStationName:station.displayName ipLiteral:station.ipAddress modelHint:station.modelHint error:NULL] validatedDescription]
            : station.displayName;
        self_.lastSections = sections;
        self_.lastProperties = rawProperties;
        self_.lastTargetDescription = targetDesc;
        self_.sections = sections;
        // Rebuilds the table and runs the Optimizations audit on this
        // fresh read (files/08 §4: the audit also refreshes when a new
        // read completes while the section is open).
        [self_ rebuildFlatRows];
        [self_.configTable reloadData];
        self_.auditButton.enabled = YES;
        NSUInteger propertyCount = rawProperties.count;
        self_.statusLabel.stringValue = [NSString stringWithFormat:@"Read %@ — %lu properties (passwords are never shown).",
                                         station.displayName, (unsigned long)propertyCount];
        [[NUJournal sharedJournal] addEntryWithKind:NUJournalEntryKindManageRead
                                              panel:@"Base Stations"
                                  targetDescription:targetDesc
                                             detail:[NSString stringWithFormat:@"configuration read — %lu properties", (unsigned long)propertyCount]];
    }];
}

#pragma mark - Optimizations audit (files/08)

- (void)auditPressed:(id)sender
{
    if (self.lastProperties == nil) return;
    [self rebuildFlatRows];
    [self.configTable reloadData];
}

// Rebuilds flatRows from the last read: the client's sections, then the
// Optimizations section, then the raw property table. Every rebuild
// runs the audit once and records that run to the Journal (files/08 §2:
// one entry per run, in the Diagnose record family — hence the
// DiagnoseRun kind below — carrying the findings summary only: titles,
// current and recommended values; never credentials, never the raw
// payload). The audit is read-only by construction: the engine performs
// no I/O and this panel offers no way to apply a finding (files/08 §1).
- (void)rebuildFlatRows
{
    NSMutableArray<NSDictionary *> *flat = [NSMutableArray array];
    for (NSDictionary *section in self.lastSections ?: @[]) {
        [flat addObject:@{@"header": @YES, @"section": section[@"title"]}];
        for (NSDictionary *row in section[@"rows"]) {
            [flat addObject:@{@"header": @NO, @"item": row[@"item"], @"value": row[@"value"]}];
        }
    }
    if (self.lastProperties != nil) {
        NSArray<NSDictionary *> *scan = self.scanNetworksProvider ? self.scanNetworksProvider() : nil;
        NSArray<NUOptimizationFinding *> *findings =
            [NUOptimizationEngine findingsFromProperties:self.lastProperties
                                            scanNetworks:scan
                                                 clients:nil];
        [flat addObject:@{@"header": @YES, @"section": @"Optimizations"}];
        if (findings.count > 0) {
            for (NUOptimizationFinding *f in findings) {
                NSString *severityWord = f.severity == NUOptimizationSeverityRecommendation ? @"Recommendation"
                                       : f.severity == NUOptimizationSeverityAdvisory       ? @"Advisory"
                                                                                            : @"For information";
                NSString *value = [NSString stringWithFormat:@"%@ · %@ → %@ — %@",
                                   severityWord, f.currentValue, f.recommendedValue, f.rationale];
                [flat addObject:@{@"header": @NO, @"item": f.title, @"value": value}];
            }
        } else if (scan.count > 0) {
            [flat addObject:@{@"header": @NO, @"item": @"No findings",
                              @"value": @"Every setting this audit could check matches its recommendation."}];
        } else {
            // Honest empty state (files/08 §4): without a survey the
            // channel checks did not run, so this is not the all-clear.
            [flat addObject:@{@"header": @NO, @"item": @"No findings",
                              @"value": @"Every setting this audit could check from the configuration matches its recommendation. No current survey was available, so the channel checks did not run."}];
        }
        [[NUJournal sharedJournal] addEntryWithKind:NUJournalEntryKindDiagnoseRun
                                              panel:@"Optimizations"
                                  targetDescription:self.lastTargetDescription ?: @"base station"
                                             detail:[NUOptimizationEngine journalSummaryFromFindings:findings]];
    }
    // Raw table as the final section (password values already excluded).
    [flat addObject:@{@"header": @YES, @"section": @"All Properties"}];
    for (NSString *key in [self.lastProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id v = self.lastProperties[key];
        NSString *value = [v isKindOfClass:[NSDictionary class]]
            ? [NSString stringWithFormat:@"(%lu entries)", (unsigned long)[(NSDictionary *)v count]]
            : (NSString *)v;
        [flat addObject:@{@"header": @NO, @"item": key, @"value": value}];
    }
    self.flatRows = [flat copy];
}

@end
