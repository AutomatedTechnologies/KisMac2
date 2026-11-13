/*
 
 File:			GrowlController.h
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

// Growl excision (SDS-10 10.6, second half; owner directive
// 2026-11-13 17:31 EST): this controller no longer imports or
// links Growl. The class name and every method signature are the
// engine's internal identifiers and stay; the implementation posts
// natively via NSUserNotificationCenter from the main bundle.
// Growl was a separate third-party application (retired 2020)
// holding a self-asserted, unauthenticated sender identity — a
// spoofing surface, not a name string.
@interface GrowlController : NSObject
{
}

- (void)registerGrowl;

+ (void)notifyGrowlOpenNetwork:(NSString *)notname
                          SSID:(NSString *)SSID
                         BSSID:(NSString *)BSSID
                        signal:(NSUInteger)signal
                       channel:(NSUInteger)channel;

+ (void)notifyGrowlUnknownNetwork:(NSString *)notname
                             SSID:(NSString *)SSID
                            BSSID:(NSString *)BSSID
                           signal:(NSUInteger)signal
                          channel:(NSUInteger)channel;

+ (void)notifyGrowlLEAPNetwork:(NSString *)notname
                          SSID:(NSString *)SSID
                         BSSID:(NSString *)BSSID
                        signal:(NSUInteger)signal
                       channel:(NSUInteger)channel;

+ (void)notifyGrowlWEPNetwork:(NSString *)notname
                         SSID:(NSString *)SSID
                        BSSID:(NSString *)BSSID
                       signal:(NSUInteger)signal
                      channel:(NSUInteger)channel;

+ (void)notifyGrowlWPANetwork:(NSString *)notname
                         SSID:(NSString *)SSID
                        BSSID:(NSString *)BSSID
                       signal:(NSUInteger)signal
                      channel:(NSUInteger)channel;

+ (void)notifyGrowlProbeRequest:(NSString *)notname
                          BSSID:(NSString *)BSSID
                         signal:(NSUInteger)signal;

+ (void)notifyGrowlStartScan;
+ (void)notifyGrowlStopScan;

+ (void)notifyGrowlWPAChallenge:(NSString *)notname mac:(NSString *)mac bssid:(NSString *)bssid;
+ (void)notifyGrowlWPAResponse:(NSString *)notname mac:(NSString *)mac bssid:(NSString *)bssid;
+ (void)notifyGrowlSSIDRevealed:(NSString *)notname BSSID:(NSString *)BSSID SSID:(NSString *)SSID;

@end
