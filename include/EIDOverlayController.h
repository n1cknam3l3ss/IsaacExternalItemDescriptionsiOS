#import <Foundation/Foundation.h>

@class EIDDescriptionStore;
@class EIDNativeProbe;
@class EIDPickupIdentity;

NS_ASSUME_NONNULL_BEGIN

@interface EIDOverlayController : NSObject
- (instancetype)initWithStore:(EIDDescriptionStore *)store probe:(EIDNativeProbe *)probe;
- (void)start;
- (void)showCollectibleID:(NSInteger)collectibleID;
- (void)setDiagnosticsEnabled:(BOOL)enabled;
- (NSString *)enrichDescription:(NSString *)originalDetail
                      forPickup:(EIDPickupIdentity *)pickup
                 displaySubtype:(NSInteger)displaySubtype;
@end

NS_ASSUME_NONNULL_END
