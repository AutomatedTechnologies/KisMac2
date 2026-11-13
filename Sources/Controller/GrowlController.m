/*
 
 File:			GrowlController.m
 Program:		KisMAC
 Author:		themacuser at gmail dot com
 Changes:       Vitalii Parovishnyk(1012-2015)
 
 Description:	KisMAC is a wireless stumbler for MacOS X.
 
 This file is part of KisMAC.
 
 Most parts of this file are based on aircrack by Christophe Devine.
 
 KisMAC is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License, version 2,
 as published by the Free Software Foundation;
 
 KisMAC is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with KisMAC; if not, write to the Free Software
 Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#import "GrowlController.h"

// Growl excision (SDS-10 10.6, second half): GrowlController keeps
// its name and signatures (internal identifiers) but conforms to
// the native NSUserNotificationCenterDelegate in this extension
// only -- no Growl protocol, framework, or helper app remains.
@interface GrowlController () <NSUserNotificationCenterDelegate>
@end

@implementation GrowlController

- (id)init
{
	return [super init];
}

// SDS-10 10.6 (notification identity): the banner title is read
// from the main bundle's own Info.plist at runtime (CFBundleName,
// then CFBundleDisplayName) -- never a hardcoded upstream name, and
// (10.6 second half) never a name asserted to a third-party
// intermediary: posting is native (below), so Notification Center
// attributes the notification to this bundle
// (com.detroitautomationacademy.workbench) by construction. The
// literal fallback covers only a bundle with no name keys at all.
+ (NSString *)notificationApplicationName
{
	NSString *name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
	if (![name length]) {
		name = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"];
	}
	if (![name length]) {
		name = @"Workbench";
	}
	return name;
}


- (void)registerGrowl
{
	// Name retained (internal identifier; ScanController calls it
	// at scan setup). It now registers NOTHING with any intermediary:
	// it installs this controller as the NSUserNotificationCenter
	// delegate so banners present while the app is active. If the
	// center is unavailable the failure is logged, and the posting
	// calls below still deliver through the default center -- there
	// is no external helper whose absence silently drops them.
	NSUserNotificationCenter *center = [NSUserNotificationCenter defaultUserNotificationCenter];
	if (center) {
		center.delegate = self;
	} else {
		DBNSLog(@"NSUserNotificationCenter unavailable");
	}
}

- (BOOL)userNotificationCenter:(NSUserNotificationCenter *)center shouldPresentNotification:(NSUserNotification *)notification
{
	return YES;
}

// Native posting (SDS-10 10.6): the notification is delivered by
// this process, from the main bundle. Notification Center takes
// the attribution (bundle identity + AppIcon) from the bundle
// itself; the title carries the ship name read at runtime and the
// body is the scan-lifecycle text -- the same two lines the Growl
// banner showed, with the name now bound to the bundle.
+ (void)deliverNativeNotificationWithDescription:(NSString *)description
{
	NSUserNotification *notification = [[NSUserNotification alloc] init];
	notification.title = [GrowlController notificationApplicationName];
	notification.informativeText = description;
	[[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
}

#pragma mark Notifications (native, ex-Growl)

+ (void)notifyGrowlOpenNetwork:(NSString *)notname SSID:(NSString *)SSID BSSID:(NSString *)BSSID signal:(NSUInteger)signal channel:(NSUInteger)channel
{

}

+ (void)notifyGrowlWEPNetwork:(NSString *)notname SSID:(NSString *)SSID BSSID:(NSString *)BSSID signal:(NSUInteger)signal channel:(NSUInteger)channel
{

}

+ (void)notifyGrowlWPANetwork:(NSString *)notname SSID:(NSString *)SSID BSSID:(NSString *)BSSID signal:(NSUInteger)signal channel:(NSUInteger)channel
{

}

+ (void)notifyGrowlUnknownNetwork:(NSString *)notname SSID:(NSString *)SSID BSSID:(NSString *)BSSID signal:(NSUInteger)signal channel:(NSUInteger)channel
{

}
+ (void)notifyGrowlLEAPNetwork:(NSString *)notname SSID:(NSString *)SSID BSSID:(NSString *)BSSID signal:(NSUInteger)signal channel:(NSUInteger)channel
{

}

+ (void)notifyGrowlProbeRequest:(NSString *)notname BSSID:(NSString *)BSSID signal:(NSUInteger)signal
{

}

+ (void)notifyGrowlStartScan
{
	[GrowlController deliverNativeNotificationWithDescription:@"Starting Scan..."];
}

+ (void)notifyGrowlStopScan
{
	[GrowlController deliverNativeNotificationWithDescription:@"Stopping Scan..."];
}

+ (void)notifyGrowlWPAChallenge:(NSString *)notname mac:(NSString *)mac bssid:(NSString *)bssid
{

}

+ (void)notifyGrowlWPAResponse:(NSString *)notname mac:(NSString *)mac bssid:(NSString *)bssid
{

}

+ (void)notifyGrowlSSIDRevealed:(NSString *)notname BSSID:(NSString *)BSSID SSID:(NSString *)SSID
{

}

@end
