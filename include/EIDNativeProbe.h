#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EIDPickupVariant) {
    EIDPickupVariantPill = 70,
    EIDPickupVariantCollectible = 100,
    EIDPickupVariantCard = 300,
    EIDPickupVariantTrinket = 350,
    // Internal display variant. Native pickups still use variant 70 with bit 11 set.
    EIDPickupVariantHorsePill = 1070,
    // Internal display variants for native room entities.
    EIDPickupVariantDiceRoom = 2001,
    EIDPickupVariantSacrificeRoom = 2002,
};

@interface EIDPickupIdentity : NSObject
@property(nonatomic, readonly) NSInteger variant;
@property(nonatomic, readonly) NSInteger subtype;
- (instancetype)initWithVariant:(NSInteger)variant subtype:(NSInteger)subtype;
@end

@interface EIDPlayerStats : NSObject
@property(nonatomic, assign) NSInteger playerType;
@property(nonatomic, assign) float moveSpeed;
@property(nonatomic, assign) float maxFireDelay;
@property(nonatomic, assign) float damage;
@property(nonatomic, assign) float tearRange;
@property(nonatomic, assign) NSInteger coins;
@property(nonatomic, assign) NSInteger bombs;
@property(nonatomic, assign) NSInteger keys;
@end

@interface EIDNativeProbe : NSObject
@property(nonatomic, copy, readonly) NSString *executableUUID;
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, readonly, getter=isSupportedBuild) BOOL supportedBuild;
@property(atomic, readonly, getter=isGameplayActive) BOOL gameplayActive;
@property(atomic, readonly, getter=isPauseStateAvailable) BOOL pauseStateAvailable;
@property(atomic, readonly, getter=isPaused) BOOL paused;
@property(atomic, readonly) uint32_t runSeed;
@property(atomic, readonly) NSUInteger runCounter;
@property(atomic, readonly, getter=isOwnedCollectibleStateAvailable) BOOL ownedCollectibleStateAvailable;
@property(atomic, readonly, getter=isInventoryStateAvailable) BOOL inventoryStateAvailable;
@property(atomic, readonly, getter=isTransformationStateAvailable) BOOL transformationStateAvailable;
@property(atomic, readonly, getter=isSuperBumActive) BOOL superBumActive;
@property(atomic, readonly, getter=isMomsHandPresent) BOOL momsHandPresent;
@property(atomic) uintptr_t primaryPlayerAddress;
@property(atomic, readonly) NSInteger primaryPlayerType;
@property(atomic, readonly, nullable) EIDPlayerStats *primaryPlayerStats;
@property(atomic, readonly) NSArray<EIDPickupIdentity *> *heldTrinketItems;
@property(atomic, readonly) NSArray<EIDPickupIdentity *> *smeltedTrinketItems;
- (void)start;
- (NSArray<EIDPickupIdentity *> *)currentDescribablePickups;
- (NSArray<EIDPickupIdentity *> *)currentInventoryItems;
- (NSInteger)ownedCollectibleCountForID:(NSInteger)collectibleID;
- (NSInteger)transformationCollectibleCountForID:(NSInteger)collectibleID;
- (NSInteger)nativeTransformationCounterForFormID:(NSInteger)formID;
// Compatibility API used by early integrations and exported diagnostic helpers.
- (NSArray<NSNumber *> *)currentCollectibleIDs;
- (BOOL)hasHolyShield;
- (BOOL)restoreHolyShield;
- (BOOL)setPlayerDamage:(float)damage;
- (BOOL)setPlayerMoveSpeed:(float)speed;
- (BOOL)setPlayerMaxFireDelay:(float)fireDelay;
#if EID_DEBUG_MENU
@property(atomic) uintptr_t nearestPickupAddress;
@property(atomic, copy) NSArray<NSNumber *> *lastPickupAddresses;
- (BOOL)transformNearestPickupToVariant:(NSInteger)variant subtype:(NSInteger)subtype;
- (BOOL)giveGulpPillToPocket;
- (BOOL)giveCardToPocket:(NSInteger)cardID;
- (BOOL)giveActiveItemToPocket:(NSInteger)collectibleID;
- (BOOL)giveConsumablesCoins:(NSInteger)coins bombs:(NSInteger)bombs keys:(NSInteger)keys;
- (BOOL)addPlayerSpeed:(float)speedDelta damage:(float)damageDelta tears:(float)tearsDelta;
- (BOOL)smeltTrinketWithPill:(NSInteger)trinketID;
- (BOOL)identifyAllPills;
- (BOOL)healPlayer;
#endif
@end

NS_ASSUME_NONNULL_END
