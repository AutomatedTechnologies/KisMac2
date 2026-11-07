//
//  NUJournalViewController.h
//  Network Utility (Switchboard V1) — Journal panel UI.
//
//  The shared local journal (spec §5.3): Diagnose run records in this
//  build. Local only — there is no send/share path; Export writes a text
//  file the user picks in a save panel. Never transmitted.
//
//  GPL-2.0 — see LICENSE.txt.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NUJournalViewController : NSViewController
@end

NS_ASSUME_NONNULL_END
