//
//  NUDiagnoseViewController.m
//  Network Utility (Switchboard V1) — Diagnose panels UI. See header.
//

#import "NUDiagnoseViewController.h"
#import "NUDiagnoseEngines.h"
#import "NUJournal.h"

typedef NS_ENUM(NSInteger, NUPanel) {
    NUPanelPing = 0,
    NUPanelNetstat,
    NUPanelTraceroute,
    NUPanelSpeedTest,
};

@interface NUDiagnoseViewController ()
@property (nonatomic, strong) NSPopUpButton *panelPopup;
@property (nonatomic, strong) NSTextField *targetField;
@property (nonatomic, strong) NSTextField *targetLabel;
@property (nonatomic, strong) NSTextField *countField;
@property (nonatomic, strong) NSTextField *countLabel;
@property (nonatomic, strong) NSButton *runButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSTextField *summaryLabel;
@property (nonatomic, strong) NSTextView *outputView;
@property (nonatomic, strong, nullable) id runningEngine;
@property (nonatomic, strong, nullable) NUTarget *runTarget;
@property (nonatomic) NUPanel runPanel;
@end

@implementation NUDiagnoseViewController

- (void)loadView
{
    // Layout note (owner UAT 2026-11-07 20:59): frames are the design
    // size; the shell stretches this view, so subviews carry autoresizing
    // masks — the control row is pinned to the top (flexible BOTTOM
    // margin), the count/run/stop group is also pinned to the right
    // (flexible LEFT margin), the target field and output view stretch.
    // Without masks the panel stayed a fixed block anchored bottom-left.
    NSView *root = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 760, 520)];

    self.panelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16, 478, 180, 26) pullsDown:NO];
    self.panelPopup.autoresizingMask = NSViewMinYMargin;
    [self.panelPopup addItemsWithTitles:@[@"Ping", @"Netstat", @"Traceroute", @"Speed Test"]];
    self.panelPopup.target = self;
    self.panelPopup.action = @selector(panelChanged:);
    [root addSubview:self.panelPopup];

    self.targetLabel = [NSTextField labelWithString:@"Target"];
    self.targetLabel.frame = NSMakeRect(212, 482, 48, 18);
    self.targetLabel.autoresizingMask = NSViewMinYMargin;
    [root addSubview:self.targetLabel];

    self.targetField = [[NSTextField alloc] initWithFrame:NSMakeRect(262, 479, 220, 24)];
    self.targetField.placeholderString = @"hostname or IP address";
    self.targetField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [root addSubview:self.targetField];

    self.countLabel = [NSTextField labelWithString:@"Count"];
    self.countLabel.frame = NSMakeRect(496, 482, 44, 18);
    self.countLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:self.countLabel];

    self.countField = [[NSTextField alloc] initWithFrame:NSMakeRect(542, 479, 48, 24)];
    self.countField.stringValue = @"10";
    self.countField.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:self.countField];

    self.runButton = [NSButton buttonWithTitle:@"Run" target:self action:@selector(runPressed:)];
    self.runButton.frame = NSMakeRect(604, 477, 64, 28);
    self.runButton.bezelStyle = NSBezelStyleRounded;
    self.runButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:self.runButton];

    self.stopButton = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopPressed:)];
    self.stopButton.frame = NSMakeRect(674, 477, 64, 28);
    self.stopButton.bezelStyle = NSBezelStyleRounded;
    self.stopButton.enabled = NO;
    self.stopButton.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [root addSubview:self.stopButton];

    self.summaryLabel = [NSTextField wrappingLabelWithString:@""];
    self.summaryLabel.frame = NSMakeRect(16, 442, 728, 30);
    self.summaryLabel.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.summaryLabel.font = [NSFont systemFontOfSize:12];
    self.summaryLabel.textColor = [NSColor colorWithCalibratedWhite:0.27 alpha:1]; // SDS muted
    [root addSubview:self.summaryLabel];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 16, 728, 418)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.outputView = [[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    self.outputView.editable = NO;
    self.outputView.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.outputView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.documentView = self.outputView;
    [root addSubview:scroll];

    self.view = root;
    [self panelChanged:nil];
}

- (NUPanel)selectedPanel
{
    return (NUPanel)self.panelPopup.indexOfSelectedItem;
}

- (void)panelChanged:(id)sender
{
    NUPanel p = [self selectedPanel];
    BOOL needsTarget = (p != NUPanelNetstat);
    self.targetField.enabled = needsTarget;
    self.targetLabel.enabled = needsTarget;
    BOOL needsCount = (p == NUPanelPing);
    self.countField.enabled = needsCount;
    self.countLabel.enabled = needsCount;
    if (p == NUPanelSpeedTest && self.targetField.stringValue.length == 0) {
        self.summaryLabel.stringValue = @"Speed Test runs the gateway leg when the target is empty, or a LAN leg to the target you enter. There is no internet leg in this build.";
    } else if (p == NUPanelNetstat) {
        self.summaryLabel.stringValue = @"Netstat shows this Mac's own routing table, interfaces, and sockets — no target needed.";
    } else {
        self.summaryLabel.stringValue = @"";
    }
}

- (void)setCurrentTarget:(NUTarget *)currentTarget
{
    _currentTarget = currentTarget;
    if (currentTarget != nil && self.targetField != nil) {
        self.targetField.stringValue = [currentTarget validatedDescription];
    }
}

#pragma mark - Output helpers

- (void)clearOutput
{
    self.outputView.string = @"";
}

- (void)appendLine:(NSString *)line
{
    NSString *text = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:text
        attributes:@{NSFontAttributeName: self.outputView.font ?: [NSFont systemFontOfSize:12]}];
    [self.outputView.textStorage appendAttributedString:as];
    [self.outputView scrollToEndOfDocument:nil];
}

- (void)setRunning:(BOOL)running
{
    self.runButton.enabled = !running;
    self.stopButton.enabled = running;
    self.panelPopup.enabled = !running;
}

- (void)finishRunWithSummary:(NSString *)summary journalDetail:(NSString *)detail
{
    if (summary.length) self.summaryLabel.stringValue = summary;
    if (self.runTarget != nil || self.runPanel == NUPanelNetstat || self.runPanel == NUPanelSpeedTest) {
        NSString *targetDesc = self.runTarget ? [self.runTarget validatedDescription]
                                              : (self.runPanel == NUPanelNetstat ? @"this Mac" : @"default gateway");
        [[NUJournal sharedJournal] addEntryWithKind:NUJournalEntryKindDiagnoseRun
                                              panel:[self panelName:self.runPanel]
                                  targetDescription:targetDesc
                                             detail:detail ?: summary ?: @""];
    }
    self.runningEngine = nil;
    self.runTarget = nil;
    [self setRunning:NO];
}

- (NSString *)panelName:(NUPanel)p
{
    switch (p) {
        case NUPanelPing: return @"Ping";
        case NUPanelNetstat: return @"Netstat";
        case NUPanelTraceroute: return @"Traceroute";
        case NUPanelSpeedTest: return @"Speed Test";
    }
    return @"Diagnose";
}

#pragma mark - Runs

- (nullable NUTarget *)validatedTargetOrReport
{
    NSString *input = [self.targetField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *error = nil;
    NUTarget *t = [NUTarget targetWithHostInput:input error:&error];
    if (t == nil) {
        self.summaryLabel.stringValue = error ?: @"Enter a valid target.";
        NSBeep();
        return nil;
    }
    return t;
}

- (void)runPressed:(id)sender
{
    if (self.runningEngine != nil) return;
    NUPanel panel = [self selectedPanel];
    self.runPanel = panel;
    [self clearOutput];

    if (panel == NUPanelNetstat) {
        self.runTarget = nil;
        [self appendLine:[NUNetstat routingTableText]];
        [self appendLine:[NUNetstat interfaceTableText]];
        [self appendLine:[NUNetstat socketTableText]];
        [self finishRunWithSummary:@"This Mac: routing table, interfaces, and sockets."
                     journalDetail:@"routing table, interfaces, and sockets displayed"];
        return;
    }

    if (panel == NUPanelSpeedTest &&
        [self.targetField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) {
        [self runSpeedTestWithTarget:nil];
        return;
    }

    NUTarget *target = [self validatedTargetOrReport];
    if (target == nil) return;
    NSString *refusalReason = nil;
    if (![target activeProbingAllowed:&refusalReason]) {
        self.summaryLabel.stringValue = refusalReason ?: @"That target is refused for active panels.";
        NSBeep();
        return;
    }
    self.runTarget = target;

    switch (panel) {
        case NUPanelPing: {
            NSInteger count = self.countField.integerValue;
            if (count < 1) count = 10;
            if (count > 100) count = 100;
            [self appendLine:[NSString stringWithFormat:@"PING %@ — %ld packets", [target validatedDescription], (long)count]];
            NUPingEngine *engine = [[NUPingEngine alloc] initWithTarget:target count:count interval:0.5];
            __weak typeof(self) weakSelf = self;
            engine.onReply = ^(uint16_t seq, double rtt) {
                [weakSelf appendLine:[NSString stringWithFormat:@"Reply %u: %.1f ms", seq + 1, rtt]];
            };
            engine.onCompletion = ^(NSDictionary *stats, NSString *error) {
                typeof(self) self_ = weakSelf;
                if (error) {
                    [self_ finishRunWithSummary:error journalDetail:error];
                    return;
                }
                NSString *summary = [NSString stringWithFormat:@"%@ packets transmitted, %@ received, %.0f%% packet loss · round-trip min/avg/max %.1f/%.1f/%.1f ms",
                    stats[@"sent"], stats[@"received"], [stats[@"lossPercent"] doubleValue],
                    [stats[@"minMs"] doubleValue], [stats[@"avgMs"] doubleValue], [stats[@"maxMs"] doubleValue]];
                [self_ appendLine:summary];
                [self_ finishRunWithSummary:summary journalDetail:summary];
            };
            self.runningEngine = engine;
            [self setRunning:YES];
            [engine start];
            break;
        }
        case NUPanelTraceroute: {
            [self appendLine:[NSString stringWithFormat:@"Traceroute to %@ (max 30 hops)", [target validatedDescription]]];
            NUTracerouteEngine *engine = [[NUTracerouteEngine alloc] initWithTarget:target maxHops:30 probeTimeout:2.0];
            __weak typeof(self) weakSelf = self;
            engine.onHop = ^(NSInteger hop, NSString *responder, NSArray<NSNumber *> *rtts, BOOL reached) {
                typeof(self) self_ = weakSelf;
                if (rtts.count == 0) {
                    [self_ appendLine:[NSString stringWithFormat:@"%2ld  * * *", (long)hop]];
                } else {
                    NSMutableString *line = [NSMutableString stringWithFormat:@"%2ld  %@  ", (long)hop, responder ?: @"?"];
                    for (NSNumber *r in rtts) [line appendFormat:@"%.1f ms  ", r.doubleValue];
                    [self_ appendLine:[line copy]];
                }
            };
            engine.onCompletion = ^(NSString *error) {
                typeof(self) self_ = weakSelf;
                [self_ finishRunWithSummary:error ?: @"Trace complete."
                              journalDetail:error ?: @"trace complete"];
            };
            self.runningEngine = engine;
            [self setRunning:YES];
            [engine start];
            break;
        }
        case NUPanelSpeedTest:
            [self runSpeedTestWithTarget:target];
            break;
        case NUPanelNetstat:
            break;
    }
}

- (void)runSpeedTestWithTarget:(nullable NUTarget *)target
{
    self.runTarget = target;
    NUSpeedTestEngine *engine = [[NUSpeedTestEngine alloc] init];
    __weak typeof(self) weakSelf = self;
    engine.onCompletion = ^(NSString *summary, NSString *error) {
        typeof(self) self_ = weakSelf;
        if (error) {
            [self_ finishRunWithSummary:error journalDetail:error];
            return;
        }
        [self_ appendLine:summary];
        [self_ finishRunWithSummary:[summary componentsSeparatedByString:@"\n"].firstObject ?: summary
                      journalDetail:[summary stringByReplacingOccurrencesOfString:@"\n" withString:@" · "]];
    };
    self.runningEngine = engine;
    [self setRunning:YES];
    if (target == nil) {
        [self appendLine:@"Gateway leg"];
        [engine runGatewayLeg];
    } else {
        [self appendLine:[NSString stringWithFormat:@"LAN leg to %@", [target validatedDescription]]];
        [engine runLANLegWithTarget:target];
    }
}

- (void)stopPressed:(id)sender
{
    id engine = self.runningEngine;
    if ([engine isKindOfClass:[NUPingEngine class]]) [(NUPingEngine *)engine cancel];
    else if ([engine isKindOfClass:[NUTracerouteEngine class]]) [(NUTracerouteEngine *)engine cancel];
    else if ([engine isKindOfClass:[NUSpeedTestEngine class]]) [(NUSpeedTestEngine *)engine cancel];
}

@end
