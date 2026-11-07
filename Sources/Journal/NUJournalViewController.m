//
//  NUJournalViewController.m
//  Network Utility (Switchboard V1) — Journal panel UI. See header.
//

#import "NUJournalViewController.h"
#import "NUJournal.h"

@interface NUJournalViewController () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSTableView *table;
@property (nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation NUJournalViewController

- (void)loadView
{
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 520)];

    NSTextField *note = [NSTextField wrappingLabelWithString:@"Local record only — stored on this Mac, never transmitted. Export writes a text file you choose."];
    note.frame = NSMakeRect(16, 488, 560, 16);
    note.font = [NSFont systemFontOfSize:12];
    note.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1]; // SDS muted
    [root addSubview:note];

    NSButton *exportButton = [NSButton buttonWithTitle:@"Export…" target:self action:@selector(exportPressed:)];
    exportButton.frame = NSMakeRect(644, 482, 100, 28);
    exportButton.bezelStyle = NSBezelStyleRounded;
    [root addSubview:exportButton];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 728, 458)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.table = [[NSTableView alloc] initWithFrame:scroll.contentView.bounds];
    NSArray *cols = @[
        @[@"when", @"When", @130],
        @[@"kind", @"Kind", @90],
        @[@"panel", @"Panel", @110],
        @[@"target", @"Target", @180],
        @[@"detail", @"Detail", @200],
    ];
    for (NSArray *c in cols) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        [self.table addTableColumn:col];
    }
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.usesAlternatingRowBackgroundColors = YES;
    scroll.documentView = self.table;
    [root addSubview:scroll];

    self.view = root;

    self.dateFormatter = [[NSDateFormatter alloc] init];
    self.dateFormatter.dateFormat = @"yyyy-MM-dd HH:mm";

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reload)
                                                 name:NUJournalDidChangeNotification
                                               object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reload
{
    [self.table reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[NUJournal sharedJournal].entries.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
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
    NUJournalEntry *e = [NUJournal sharedJournal].entries[(NSUInteger)row];
    NSString *value = @"";
    if ([tableColumn.identifier isEqualToString:@"when"]) value = [self.dateFormatter stringFromDate:e.date];
    else if ([tableColumn.identifier isEqualToString:@"kind"]) {
        value = e.kind == NUJournalEntryKindDiagnoseRun ? @"Diagnose" :
                e.kind == NUJournalEntryKindManageRead  ? @"Manage read" : @"Shell";
    }
    else if ([tableColumn.identifier isEqualToString:@"panel"]) value = e.panel;
    else if ([tableColumn.identifier isEqualToString:@"target"]) value = e.targetDescription;
    else if ([tableColumn.identifier isEqualToString:@"detail"]) value = e.detail;
    cell.textField.stringValue = value ?: @"";
    return cell;
}

#pragma mark - Export

- (void)exportPressed:(id)sender
{
    NSString *text = [[NUJournal sharedJournal] exportText];
    if (text == nil) { NSBeep(); return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"NetworkUtility-Journal.txt";
    panel.allowedFileTypes = @[@"txt"];
    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        [text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

@end
