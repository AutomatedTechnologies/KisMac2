//
//  NUShellController.m
//  Network Utility (Switchboard V1) — unified shell. See header.
//
//  Hosting contract for the Networks section: the shell takes the KisMac
//  scan window's toolbar and content view and hosts them; the original
//  window is ordered out WITHOUT being closed, so the scan controller's
//  window outlet stays valid and Discover behaves exactly as before. If
//  the scan window cannot be found, the shell still opens with a plain
//  fallback message and the app's own window is left untouched. Closing
//  the shell window restores the scan window to its hosted state.
//

#import "NUShellController.h"
#import "NUDiagnoseViewController.h"
#import "NUManageViewController.h"
#import "NUJournalViewController.h"
#import "NUJournal.h"

#import <CoreWLAN/CoreWLAN.h>

typedef NS_ENUM(NSInteger, NUSection) {
    NUSectionNetworks = 0,
    NUSectionBaseStations,
    NUSectionDiagnose,
    NUSectionJournal,
};

static NSString * const kClassroomDefaultsKey = @"NUClassroomMode";

@interface NUShellController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTableView *sidebar;
@property (nonatomic, strong) NSView *contentContainer;
@property (nonatomic, strong) NSTextField *radioLabel;
@property (nonatomic, strong) NSTextField *targetLabel;
@property (nonatomic, strong) NSTextField *journalLabel;
@property (nonatomic, strong) NSButton *classroomCheckbox;
@property (nonatomic, strong, nullable) NSWindow *hostedWindow;   // the KisMac scan window
@property (nonatomic, strong, nullable) NSView *hostedContent;     // its original content view
@property (nonatomic, strong, nullable) NSToolbar *hostedToolbar;  // its original toolbar
@property (nonatomic, strong) NSMutableDictionary *wrappedToolbarItems; // itemIdentifier -> @{target, action} it had before wrapping
@property (nonatomic, strong) NSView *networksContainer;
@property (nonatomic, strong) NUManageViewController *manageVC;
@property (nonatomic, strong) NUDiagnoseViewController *diagnoseVC;
@property (nonatomic, strong) NUJournalViewController *journalVC;
@property (nonatomic) NUSection currentSection;
@property (nonatomic) BOOL installed;
@property (nonatomic) NSInteger hostingAttempts;
@end

@implementation NUShellController

+ (void)load
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(nuApplicationDidFinishLaunching:)
                                                 name:NSApplicationDidFinishLaunchingNotification
                                               object:nil];
}

+ (void)nuApplicationDidFinishLaunching:(NSNotification *)note
{
    [[self sharedController] install];
}

+ (instancetype)sharedController
{
    static NUShellController *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

#pragma mark - Sidebar model

- (NSArray *)sidebarRows
{
    // @{header: title} or @{section: NSNumber, title:, icon:}
    return @[
        @{@"header": @"NETWORKS"},
        @{@"section": @(NUSectionNetworks), @"title": @"Networks", @"icon": @"icon-networks"},
        @{@"header": @"BASE STATIONS"},
        @{@"section": @(NUSectionBaseStations), @"title": @"Base Stations", @"icon": @"icon-details"},
        @{@"header": @"DIAGNOSTICS"},
        @{@"section": @(NUSectionDiagnose), @"title": @"Diagnose", @"icon": @"icon-graph"},
        @{@"section": @(NUSectionJournal), @"title": @"Journal", @"icon": @"icon-save"},
    ];
}

#pragma mark - Install

- (void)install
{
    if (self.installed) return;
    self.installed = YES;

    NSRect frame = NSMakeRect(0, 0, 1080, 680);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Workbench";
    window.minSize = NSMakeSize(880, 560);
    window.delegate = self;
    [window center];
    self.window = window;

    NSView *root = window.contentView;

    // Sidebar (SDS: panel backing, muted small-caps section headers).
    NSScrollView *sideScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 28, 208, 652)];
    sideScroll.autoresizingMask = NSViewHeightSizable;
    sideScroll.hasVerticalScroller = YES;
    sideScroll.borderType = NSNoBorder;
    self.sidebar = [[NSTableView alloc] initWithFrame:sideScroll.contentView.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"item"];
    col.width = 200;
    [self.sidebar addTableColumn:col];
    self.sidebar.headerView = nil;
    self.sidebar.dataSource = self;
    self.sidebar.delegate = self;
    self.sidebar.rowHeight = 24;
    self.sidebar.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
    self.sidebar.backgroundColor = [NSColor colorWithCalibratedWhite:0.957 alpha:1]; // SDS panel #f4f4f4
    sideScroll.documentView = self.sidebar;
    [root addSubview:sideScroll];

    // Content container.
    self.contentContainer = [[NSView alloc] initWithFrame:NSMakeRect(208, 28, 872, 652)];
    self.contentContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.contentContainer];

    // Status bar — always visible (spec §5.1): hairline top, panel backing.
    // Pinned to the window's BOTTOM edge: the flexible margin must be the
    // TOP one (NSViewMaxYMargin). NSViewMinYMargin here made the bottom
    // margin flexible instead, so on any window taller than the initial
    // frame the bar stayed at a fixed distance from the top and floated
    // up into the content area, which then slid underneath it (owner UAT
    // 2026-11-07 20:59: status text half-covered by the section panel).
    NSView *statusBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1080, 28)];
    statusBar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    statusBar.wantsLayer = YES;
    statusBar.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.957 alpha:1].CGColor;
    [root addSubview:statusBar];

    self.radioLabel = [NSTextField labelWithString:@"Radio: —"];
    self.radioLabel.frame = NSMakeRect(10, 6, 260, 16);
    self.radioLabel.font = [NSFont systemFontOfSize:12];
    [statusBar addSubview:self.radioLabel];

    self.targetLabel = [NSTextField labelWithString:@"Target: —"];
    self.targetLabel.frame = NSMakeRect(280, 6, 300, 16);
    self.targetLabel.font = [NSFont systemFontOfSize:12];
    self.targetLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusBar addSubview:self.targetLabel];

    self.journalLabel = [NSTextField labelWithString:@"Journal: no entries yet"];
    self.journalLabel.frame = NSMakeRect(590, 6, 330, 16);
    self.journalLabel.autoresizingMask = NSViewWidthSizable;
    self.journalLabel.font = [NSFont systemFontOfSize:12];
    self.journalLabel.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1]; // SDS muted
    self.journalLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [statusBar addSubview:self.journalLabel];

    self.classroomCheckbox = [NSButton checkboxWithTitle:@"Classroom mode" target:self action:@selector(classroomToggled:)];
    self.classroomCheckbox.frame = NSMakeRect(936, 4, 140, 20);
    self.classroomCheckbox.autoresizingMask = NSViewMinXMargin; // stays pinned to the bar's right edge
    self.classroomCheckbox.font = [NSFont systemFontOfSize:12];
    self.classroomCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:kClassroomDefaultsKey]
        ? NSControlStateValueOn : NSControlStateValueOff;
    self.classroomCheckbox.toolTip = @"Observation only: Manage stays read-only and no credential prompt is shown.";
    [statusBar addSubview:self.classroomCheckbox];

    [self.sidebar reloadData];
    [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [self showSection:NUSectionNetworks];

    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    [self updateRadioLabel];
    [self updateJournalLabel];
    [NSTimer scheduledTimerWithTimeInterval:5.0 target:self selector:@selector(updateRadioLabel) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateJournalLabel)
                                                 name:NUJournalDidChangeNotification
                                               object:nil];
    [self attemptHosting];
}

#pragma mark - Networks hosting

- (void)attemptHosting
{
    if (self.hostedContent != nil) return;
    NSWindow *scanWindow = nil;
    for (NSWindow *w in [NSApp windows]) {
        if (w != self.window && ([w.title isEqualToString:@"KisMAC"] || [w.title isEqualToString:@"KisMac"])) {
            scanWindow = w;
            break;
        }
    }
    if (scanWindow == nil) {
        self.hostingAttempts++;
        if (self.hostingAttempts <= 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [self attemptHosting]; });
        } else if (self.networksContainer != nil) {
            for (NSView *v in self.networksContainer.subviews) [v removeFromSuperview];
            NSTextField *fallback = [NSTextField wrappingLabelWithString:
                @"The scanner window was not found, so Networks is unavailable in this shell. "
                @"The other sections work normally. (The scan window was left untouched.)"];
            fallback.frame = NSMakeRect(24, 24, 420, 60);
            [self.networksContainer addSubview:fallback];
        }
        return;
    }

    self.hostedWindow = scanWindow;
    self.hostedContent = scanWindow.contentView;
    self.hostedToolbar = scanWindow.toolbar;
    if (self.hostedToolbar != nil) {
        scanWindow.toolbar = nil;
        self.window.toolbar = self.hostedToolbar;
        [self wrapViewSwitchToolbarItems];
    }
    [self.hostedContent removeFromSuperview];
    self.hostedContent.frame = self.networksContainer.bounds;
    self.hostedContent.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.networksContainer addSubview:self.hostedContent];
    [scanWindow orderOut:nil];
    [self updateRadioLabel];
}

- (void)restoreHosting
{
    if (self.hostedWindow == nil || self.hostedContent == nil) return;
    [self.hostedContent removeFromSuperview];
    self.hostedWindow.contentView = self.hostedContent;
    if (self.hostedToolbar != nil) {
        [self unwrapViewSwitchToolbarItems];
        self.window.toolbar = nil;
        self.hostedWindow.toolbar = self.hostedToolbar;
    }
    [self.hostedWindow makeKeyAndOrderFront:nil];
    self.hostedContent = nil;
    self.hostedToolbar = nil;
    self.hostedWindow = nil;
}

- (void)windowWillClose:(NSNotification *)notification
{
    if (notification.object == self.window) [self restoreHosting];
}

#pragma mark - Toolbar view-switch routing

// The hosted toolbar's view-switch items (Networks / Graph / Details /
// Map) act on the scanner's canvas, which lives inside the Networks
// section. While another section is showing, a click switched a view the
// user could not see — the items read as dead (owner UAT 2026-11-07
// 20:59: "several non-functioning tabs including graph"). While the
// toolbar is hosted here, those four items route through the shell: the
// Networks section comes forward first, then the item's original action
// runs unchanged. Original target/action are restored before the toolbar
// is handed back to the scan window.
- (BOOL)isViewSwitchAction:(SEL)action
{
    return action == @selector(showNetworks:) || action == @selector(showTrafficView:) ||
           action == @selector(showDetails:)  || action == @selector(showMap:);
}

- (void)wrapViewSwitchToolbarItems
{
    if (self.wrappedToolbarItems == nil) self.wrappedToolbarItems = [NSMutableDictionary dictionary];
    for (NSToolbarItem *item in self.hostedToolbar.items) {
        if (item.target == nil || ![self isViewSwitchAction:item.action]) continue;
        if (self.wrappedToolbarItems[item.itemIdentifier] != nil) continue;
        self.wrappedToolbarItems[item.itemIdentifier] = @{
            @"target": item.target,
            @"action": NSStringFromSelector(item.action),
        };
        item.target = self;
        item.action = @selector(nuToolbarViewSwitch:);
    }
}

- (void)unwrapViewSwitchToolbarItems
{
    for (NSToolbarItem *item in self.hostedToolbar.items) {
        NSDictionary *orig = self.wrappedToolbarItems[item.itemIdentifier];
        if (orig == nil) continue;
        item.target = orig[@"target"];
        item.action = NSSelectorFromString(orig[@"action"]);
    }
    [self.wrappedToolbarItems removeAllObjects];
}

- (void)nuToolbarViewSwitch:(NSToolbarItem *)sender
{
    NSDictionary *orig = self.wrappedToolbarItems[sender.itemIdentifier];
    if (orig == nil) return;
    [self.sidebar selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
    [self showSection:NUSectionNetworks];
    [NSApp sendAction:NSSelectorFromString(orig[@"action"]) to:orig[@"target"] from:sender];
}

#pragma mark - Sections

- (NSView *)networksContainer
{
    if (_networksContainer == nil) {
        _networksContainer = [[NSView alloc] initWithFrame:self.contentContainer.bounds];
        _networksContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTextField *starting = [NSTextField labelWithString:@"Starting the scanner…"];
        starting.frame = NSMakeRect(24, 24, 300, 20);
        starting.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1];
        [_networksContainer addSubview:starting];
    }
    return _networksContainer;
}

- (void)showSection:(NUSection)section
{
    self.currentSection = section;
    NSView *view = nil;
    switch (section) {
        case NUSectionNetworks:
            view = self.networksContainer;
            break;
        case NUSectionBaseStations: {
            if (self.manageVC == nil) {
                self.manageVC = [[NUManageViewController alloc] init];
                __weak typeof(self) weakSelf = self;
                self.manageVC.onSelectTarget = ^(NUTarget *target) { weakSelf.currentTarget = target; };
            }
            view = self.manageVC.view;
            break;
        }
        case NUSectionDiagnose: {
            if (self.diagnoseVC == nil) {
                self.diagnoseVC = [[NUDiagnoseViewController alloc] init];
                self.diagnoseVC.currentTarget = self.currentTarget;
            }
            view = self.diagnoseVC.view;
            break;
        }
        case NUSectionJournal: {
            if (self.journalVC == nil) self.journalVC = [[NUJournalViewController alloc] init];
            view = self.journalVC.view;
            break;
        }
    }
    for (NSView *v in [self.contentContainer.subviews copy]) [v removeFromSuperview];
    if (view != nil) {
        view.frame = self.contentContainer.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [self.contentContainer addSubview:view];
    }
}

- (void)setCurrentTarget:(NUTarget *)currentTarget
{
    _currentTarget = currentTarget;
    self.targetLabel.stringValue = currentTarget
        ? [NSString stringWithFormat:@"Target: %@", [currentTarget validatedDescription]]
        : @"Target: —";
    if (self.diagnoseVC != nil) self.diagnoseVC.currentTarget = currentTarget;
}

#pragma mark - Status bar

- (void)updateRadioLabel
{
    CWInterface *iface = [[CWWiFiClient sharedWiFiClient] interface];
    if (iface == nil) {
        self.radioLabel.stringValue = @"Radio: no Wi-Fi interface";
        return;
    }
    if (!iface.powerOn) {
        self.radioLabel.stringValue = @"Radio: Wi-Fi off";
        return;
    }
    NSString *ssid = iface.ssid;
    self.radioLabel.stringValue = ssid.length
        ? [NSString stringWithFormat:@"Radio: Wi-Fi on · %@", ssid]
        : @"Radio: Wi-Fi on · not associated";
}

- (void)updateJournalLabel
{
    NUJournalEntry *latest = [NUJournal sharedJournal].entries.firstObject;
    if (latest == nil) {
        self.journalLabel.stringValue = @"Journal: no entries yet";
        return;
    }
    NSString *text = [NSString stringWithFormat:@"Journal: %@ — %@", latest.panel, latest.detail];
    if (text.length > 64) text = [[text substringToIndex:61] stringByAppendingString:@"…"];
    self.journalLabel.stringValue = text;
}

- (void)classroomToggled:(id)sender
{
    BOOL on = (self.classroomCheckbox.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kClassroomDefaultsKey];
    [[NUJournal sharedJournal] addEntryWithKind:NUJournalEntryKindShellEvent
                                          panel:@"Shell"
                              targetDescription:@"this Mac"
                                         detail:on ? @"Classroom mode on (observation only)"
                                                   : @"Classroom mode off"];
}

#pragma mark - Sidebar data source / delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return (NSInteger)[self sidebarRows].count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    NSDictionary *item = [self sidebarRows][(NSUInteger)row];
    BOOL isHeader = item[@"header"] != nil;
    NSTableCellView *cell = [tableView makeViewWithIdentifier:isHeader ? @"header" : @"row" owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.frame = NSMakeRect(28, 3, 168, 18);
        [cell addSubview:tf];
        cell.textField = tf;
        NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(6, 3, 18, 18)];
        [cell addSubview:iv];
        cell.imageView = iv;
        cell.identifier = isHeader ? @"header" : @"row";
    }
    if (isHeader) {
        cell.textField.stringValue = item[@"header"];
        cell.textField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        cell.textField.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1]; // SDS muted
        cell.imageView.image = nil;
    } else {
        cell.textField.stringValue = item[@"title"];
        cell.textField.font = [NSFont systemFontOfSize:13];
        cell.textField.textColor = [NSColor blackColor]; // SDS ink
        NSImage *icon = [NSImage imageNamed:item[@"icon"]];
        icon.template = YES;
        cell.imageView.image = icon;
    }
    return cell;
}

- (BOOL)tableView:(NSTableView *)tableView isGroupRow:(NSInteger)row
{
    return [self sidebarRows][(NSUInteger)row][@"header"] != nil;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row
{
    return [self sidebarRows][(NSUInteger)row][@"header"] == nil;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row
{
    return [self sidebarRows][(NSUInteger)row][@"header"] != nil ? 20 : 26;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
    NSInteger row = self.sidebar.selectedRow;
    if (row < 0) return;
    NSDictionary *item = [self sidebarRows][(NSUInteger)row];
    if (item[@"section"] == nil) return;
    [self showSection:(NUSection)[item[@"section"] integerValue]];
}

@end
