//
//  KMImageCache.m
//  KisMac
//
//  See KMImageCache.h for the F-06 rationale.
//

#import "KMImageCache.h"
#import <AppKit/AppKit.h>

@interface KMImageCache ()
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *cache;
@end

@implementation KMImageCache

+ (instancetype)sharedCache
{
    static KMImageCache *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[KMImageCache alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.name = @"KMImageCache";
    }
    return self;
}

- (NSImage *)objectForKeyedSubscript:(NSString *)key
{
    return [self.cache objectForKey:key];
}

- (void)setObject:(NSImage *)object forKeyedSubscript:(NSString *)key
{
    if (object != nil && key != nil) {
        [self.cache setObject:object forKey:key];
    }
}

@end
