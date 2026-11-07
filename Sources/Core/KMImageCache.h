//
//  KMImageCache.h
//  KisMac
//
//  F-06 (submodule disposition) — replacement for the GBStorage submodule.
//
//  Inventory (grep-verified, Cycle 2 N1): every GBStorage use in the app was
//  an in-memory NSImage cache lookup — objectForKeyedSubscript: /
//  setObject:forKeyedSubscript: only. No caller ever invoked save:, saveAll,
//  preload, removal, the delegate, or a custom serialiser, so GBStorage's
//  disk persistence was dead weight — and its default NSCoding deserialiser
//  decodes disk files with +[NSKeyedUnarchiver unarchiveObjectWithData:],
//  the unrestricted-unarchiving class of F-11. Replacing the submodule with
//  this NSCache-backed cache removes that latent path entirely instead of
//  vendoring and patching 700 lines the app does not need.
//
//  Behaviour: a cache miss returns nil exactly as before; every call site
//  already falls back to +[NSImage imageNamed:] on a miss. NSCache is
//  thread-safe and evicts under memory pressure, which is strictly better
//  than GBStorage's unlimited in-memory default for image assets.
//

#import <Foundation/Foundation.h>

@class NSImage;

@interface KMImageCache : NSObject

+ (instancetype)sharedCache;

- (NSImage *)objectForKeyedSubscript:(NSString *)key;
- (void)setObject:(NSImage *)object forKeyedSubscript:(NSString *)key;

@end
