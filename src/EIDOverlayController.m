#import "EIDOverlayController.h"
#import "EIDDescriptionStore.h"
#import "EIDNativeProbe.h"
#import "EIDLogger.h"
#import "EIDTransformationProgress.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

static const CGFloat EIDDefaultOverlayLeftMargin = 140.0;
static const CGFloat EIDDefaultOverlayTopMargin = 50.0;
static const CGFloat EIDMinimumOverlayLeftMargin = 20.0;
static const CGFloat EIDMinimumOverlayTopMargin = 20.0;
static const CGFloat EIDOverlayRightMargin = 14.0;
static const CGFloat EIDItemIconSize = 28.0;
static const CGFloat EIDItemIconSpacing = 6.0;
static NSString *const EIDHorizontalPositionKey = @"IsaacEIDHorizontalPosition";
static NSString *const EIDVerticalPositionKey = @"IsaacEIDVerticalPosition";

static NSString *EIDGameResourcePath(NSString *relativePath) {
    NSArray<NSString *> *roots = @[@"repentance-resources", @"afterbirthplus-resources",
                                    @"afterbirth-resources", @"rebirth-resources"];
    for (NSString *root in roots) {
        NSString *candidate = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@/data/%@", root, relativePath]];
        if ([[NSFileManager defaultManager] isReadableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

@interface EIDCardAtlasParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray *frames;
@property(nonatomic) BOOL readingCardAnimation;
@property(nonatomic) BOOL readingCardLayer;
@end

@implementation EIDCardAtlasParser
- (instancetype)init {
    self = [super init];
    if (self) _frames = [NSMutableArray array];
    return self;
}

- (void)parser:(NSXMLParser *)parser
 didStartElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName
      attributes:(NSDictionary<NSString *, NSString *> *)attributes {
    (void)parser; (void)namespaceURI; (void)qualifiedName;
    if ([elementName isEqualToString:@"Animation"]) {
        self.readingCardAnimation = [attributes[@"Name"] isEqualToString:@"CardFronts"];
        self.readingCardLayer = NO;
        return;
    }
    if (self.readingCardAnimation && [elementName isEqualToString:@"LayerAnimation"]) {
        self.readingCardLayer = [attributes[@"LayerId"] integerValue] == 0;
        return;
    }
    if (!self.readingCardLayer || ![elementName isEqualToString:@"Frame"]) return;
    CGFloat x = [attributes[@"XCrop"] doubleValue];
    CGFloat y = [attributes[@"YCrop"] doubleValue];
    CGFloat width = [attributes[@"Width"] doubleValue];
    CGFloat height = [attributes[@"Height"] doubleValue];
    BOOL visible = ![attributes[@"Visible"] isEqualToString:@"false"];
    if (visible && width > 0 && height > 0) {
        [self.frames addObject:[NSValue valueWithCGRect:CGRectMake(x, y, width, height)]];
    } else {
        [self.frames addObject:NSNull.null];
    }
}

- (void)parser:(NSXMLParser *)parser
   didEndElement:(NSString *)elementName
    namespaceURI:(NSString *)namespaceURI
   qualifiedName:(NSString *)qualifiedName {
    (void)parser; (void)namespaceURI; (void)qualifiedName;
    if ([elementName isEqualToString:@"LayerAnimation"]) self.readingCardLayer = NO;
    if ([elementName isEqualToString:@"Animation"] && self.readingCardAnimation) {
        self.readingCardAnimation = NO;
    }
}
@end

@interface EIDPassthroughView : UIView
@end
@implementation EIDPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (!hit || hit == self) return nil;
    if ([hit isKindOfClass:UIControl.class]) return hit;
    // Scroll views and table-style rows inside EID cards must receive drags.
    // Everything else remains transparent to Isaac's own touch surface.
    for (UIView *view = hit; view && view != self; view = view.superview) {
        if (view.tag == 0xE1D) return hit;
    }
    return nil;
}
@end

@interface EIDOverlayController ()
@property(nonatomic, strong) EIDDescriptionStore *store;
@property(nonatomic, strong) EIDNativeProbe *probe;
@property(nonatomic, strong) EIDPassthroughView *rootView;
@property(nonatomic, strong) UIView *panel;
@property(nonatomic, strong) UIImageView *itemIconView;
@property(nonatomic, strong) UILabel *label;
@property(nonatomic, strong) UILabel *diagnosticsLabel;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic, strong) UIView *settingsCard;
@property(nonatomic, strong) UIButton *inventoryButton;
@property(nonatomic, strong) UIView *inventoryCard;
@property(nonatomic, strong) UIScrollView *inventoryScrollView;
@property(nonatomic, strong) UIButton *settingsLanguageButton;
@property(nonatomic, strong) UILabel *settingsPositionLabel;
@property(nonatomic, strong) UILabel *settingsVersionLabel;
@property(nonatomic, strong) UISlider *settingsPositionSlider;
@property(nonatomic, strong) UILabel *settingsVerticalPositionLabel;
@property(nonatomic, strong) UISlider *settingsVerticalPositionSlider;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, copy) NSArray<EIDPickupIdentity *> *lastPickups;
@property(nonatomic, strong) UIImage *cardAtlas;
@property(nonatomic, copy) NSArray *cardAtlasFrames;
@property(nonatomic, strong) UIImage *genericCardIcon;
@property(nonatomic, strong) UIImage *genericPillIcon;
@property(nonatomic, strong) NSMutableDictionary<NSString *, id> *pocketIconCache;
@property(nonatomic) BOOL diagnosticsEnabled;
@property(nonatomic) BOOL scanInProgress;
@property(nonatomic) BOOL loggedOverlayLayout;
@property(nonatomic) BOOL menuMode;
@property(nonatomic) NSUInteger consecutiveMenuScans;
@property(nonatomic, strong) EIDPickupIdentity *selectedInventoryItem;
@property(nonatomic, copy) NSString *inventorySignature;
@property(nonatomic, copy) NSString *transformationProgressSignature;
@property(nonatomic) BOOL pauseUIActive;
#if EID_DEBUG_MENU
@property(nonatomic, strong) UIButton *debugButton;
@property(nonatomic, strong) UIView *debugCard;
@property(nonatomic, strong) UIScrollView *debugScrollView;
@property(nonatomic, strong) UILabel *debugStatusLabel;
#endif
@end

@implementation EIDOverlayController
- (instancetype)initWithStore:(EIDDescriptionStore *)store probe:(EIDNativeProbe *)probe {
    self = [super init];
    if (self) {
        _store = store;
        _probe = probe;
        [EIDTransformationProgress shared].probe = probe;
        _lastPickups = @[];
        _pocketIconCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (CGFloat)overlayLeftMargin {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:EIDHorizontalPositionKey];
    CGFloat value = saved ? saved.doubleValue : EIDDefaultOverlayLeftMargin;
    CGFloat maximum = self.rootView.bounds.size.width > 0
        ? MAX(EIDDefaultOverlayLeftMargin, self.rootView.bounds.size.width - 220.0) : 360.0;
    return MIN(maximum, MAX(EIDMinimumOverlayLeftMargin, round(value)));
}

- (CGFloat)overlayTopMargin {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:EIDVerticalPositionKey];
    CGFloat value = saved ? saved.doubleValue : EIDDefaultOverlayTopMargin;
    CGFloat maximum = self.rootView.bounds.size.height > 0
        ? MAX(EIDDefaultOverlayTopMargin, self.rootView.bounds.size.height - 120.0) : 300.0;
    return MIN(maximum, MAX(EIDMinimumOverlayTopMargin, round(value)));
}

- (void)start {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self attachOverlayIfNeeded];
        [self.probe start];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                     target:self
                                                   selector:@selector(tick:)
                                                   userInfo:nil
                                                    repeats:YES];
    });
}

- (UIWindow *)gameWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0 && window.windowLevel == UIWindowLevelNormal) return window;
        }
    }
    return nil;
}

- (void)attachOverlayIfNeeded {
    UIWindow *window = [self gameWindow];
    if (!window) return;
    if (self.rootView.superview == window) return;
    [self.rootView removeFromSuperview];

    EIDPassthroughView *root = [[EIDPassthroughView alloc] initWithFrame:window.bounds];
    root.backgroundColor = UIColor.clearColor;
    root.userInteractionEnabled = YES;
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    CGFloat leftMargin = [self overlayLeftMargin];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.frame = CGRectMake(leftMargin, [self overlayTopMargin],
                             MIN(340, window.bounds.size.width - leftMargin - EIDOverlayRightMargin),
                             80);
    panel.backgroundColor = UIColor.clearColor;
    panel.clipsToBounds = NO;
    panel.alpha = 0;
    panel.userInteractionEnabled = YES;
    panel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;

    UILabel *label = [[UILabel alloc] initWithFrame:panel.bounds];
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    label.adjustsFontSizeToFitWidth = NO;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.shadowColor = [UIColor colorWithWhite:0 alpha:0.95];
    label.shadowOffset = CGSizeMake(1, 1);
    label.userInteractionEnabled = NO;
    [panel addSubview:label];

    UIImageView *itemIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    itemIcon.contentMode = UIViewContentModeScaleAspectFit;
    itemIcon.layer.magnificationFilter = kCAFilterNearest;
    itemIcon.layer.minificationFilter = kCAFilterNearest;
    itemIcon.userInteractionEnabled = NO;
    itemIcon.hidden = YES;
    [panel insertSubview:itemIcon belowSubview:label];

    UILabel *diagnostics = [[UILabel alloc] initWithFrame:
        CGRectMake(leftMargin, window.bounds.size.height - 50,
                   window.bounds.size.width - leftMargin - EIDOverlayRightMargin, 36)];
    diagnostics.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    diagnostics.textColor = UIColor.systemGreenColor;
    diagnostics.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    diagnostics.numberOfLines = 2;
    diagnostics.layer.cornerRadius = 6;
    diagnostics.layer.masksToBounds = YES;
    diagnostics.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    diagnostics.hidden = !self.diagnosticsEnabled;

    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsButton.frame = CGRectMake(window.bounds.size.width - 78,
                                      window.bounds.size.height - 46, 64, 32);
    settingsButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    settingsButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.72];
    settingsButton.layer.cornerRadius = 8;
    settingsButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [settingsButton setTitle:@"EID ⚙" forState:UIControlStateNormal];
    [settingsButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [settingsButton addTarget:self action:@selector(toggleSettings:) forControlEvents:UIControlEventTouchUpInside];
    settingsButton.hidden = !self.menuMode;

    UIButton *inventoryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    inventoryButton.frame = CGRectMake(14, 14, 88, 34);
    inventoryButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    inventoryButton.layer.cornerRadius = 8;
    inventoryButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    inventoryButton.layer.borderWidth = 1;
    inventoryButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [inventoryButton setTitle:@"EID Items" forState:UIControlStateNormal];
    [inventoryButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [inventoryButton addTarget:self action:@selector(toggleInventory:)
              forControlEvents:UIControlEventTouchUpInside];
    inventoryButton.hidden = YES;

#if EID_DEBUG_MENU
    UIButton *debugButton = [UIButton buttonWithType:UIButtonTypeSystem];
    debugButton.frame = CGRectMake(110, 14, 88, 34);
    debugButton.backgroundColor = [UIColor colorWithRed:0.75 green:0.22 blue:0.17 alpha:0.88];
    debugButton.layer.cornerRadius = 8;
    debugButton.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    debugButton.layer.borderWidth = 1;
    debugButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [debugButton setTitle:@"🛠 Debug" forState:UIControlStateNormal];
    [debugButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [debugButton addTarget:self action:@selector(toggleDebugMenu:)
          forControlEvents:UIControlEventTouchUpInside];
    debugButton.hidden = YES;
#endif

    CGFloat cardWidth = MIN(410, window.bounds.size.width - 40);
    CGFloat cardHeight = MIN(310, window.bounds.size.height - 30);
    UIView *settingsCard = [[UIView alloc] initWithFrame:
        CGRectMake((window.bounds.size.width - cardWidth) * 0.5,
                   (window.bounds.size.height - cardHeight) * 0.5, cardWidth, cardHeight)];
    settingsCard.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    settingsCard.backgroundColor = [UIColor colorWithWhite:0.035 alpha:0.94];
    settingsCard.layer.cornerRadius = 14;
    settingsCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    settingsCard.layer.borderWidth = 1;
    settingsCard.tag = 0xE1D;
    settingsCard.hidden = YES;

    UILabel *settingsTitle = [[UILabel alloc] initWithFrame:CGRectMake(18, 10, cardWidth - 72, 27)];
    settingsTitle.text = @"Isaac EID Settings";
    settingsTitle.textColor = UIColor.whiteColor;
    settingsTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    [settingsCard addSubview:settingsTitle];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.frame = CGRectMake(cardWidth - 48, 7, 38, 32);
    closeButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    closeButton.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [closeButton setTitle:@"×" forState:UIControlStateNormal];
    [closeButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [closeButton addTarget:self action:@selector(closeSettings:) forControlEvents:UIControlEventTouchUpInside];
    [settingsCard addSubview:closeButton];

    UILabel *versionLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 37, cardWidth - 36, 20)];
    versionLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1];
    versionLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
    [settingsCard addSubview:versionLabel];

    UILabel *languageLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 66, 90, 32)];
    languageLabel.text = @"Language";
    languageLabel.textColor = UIColor.whiteColor;
    languageLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [settingsCard addSubview:languageLabel];

    UIButton *languageSelector = [UIButton buttonWithType:UIButtonTypeSystem];
    languageSelector.frame = CGRectMake(110, 66, cardWidth - 128, 32);
    languageSelector.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    languageSelector.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    languageSelector.layer.cornerRadius = 7;
    languageSelector.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [languageSelector setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [languageSelector addTarget:self action:@selector(showLanguagePicker:)
               forControlEvents:UIControlEventTouchUpInside];
    [settingsCard addSubview:languageSelector];

    UILabel *positionLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, 108, cardWidth - 36, 22)];
    positionLabel.textColor = UIColor.whiteColor;
    positionLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    [settingsCard addSubview:positionLabel];

    UISlider *positionSlider = [[UISlider alloc] initWithFrame:CGRectMake(18, 132, cardWidth - 104, 32)];
    positionSlider.minimumValue = EIDMinimumOverlayLeftMargin;
    positionSlider.maximumValue = MAX(EIDDefaultOverlayLeftMargin, window.bounds.size.width - 220.0);
    positionSlider.value = [self overlayLeftMargin];
    [positionSlider addTarget:self action:@selector(positionChanged:) forControlEvents:UIControlEventValueChanged];
    [settingsCard addSubview:positionSlider];

    UIButton *resetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    resetButton.frame = CGRectMake(cardWidth - 78, 132, 60, 32);
    resetButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    resetButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [resetButton setTitle:@"Reset" forState:UIControlStateNormal];
    [resetButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [resetButton addTarget:self action:@selector(resetPosition:) forControlEvents:UIControlEventTouchUpInside];
    [settingsCard addSubview:resetButton];

    UILabel *verticalPositionLabel = [[UILabel alloc] initWithFrame:
        CGRectMake(18, 168, cardWidth - 36, 22)];
    verticalPositionLabel.textColor = UIColor.whiteColor;
    verticalPositionLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightSemibold];
    [settingsCard addSubview:verticalPositionLabel];

    UISlider *verticalPositionSlider = [[UISlider alloc] initWithFrame:
        CGRectMake(18, 192, cardWidth - 104, 32)];
    verticalPositionSlider.minimumValue = EIDMinimumOverlayTopMargin;
    verticalPositionSlider.maximumValue = MAX(EIDDefaultOverlayTopMargin,
                                               window.bounds.size.height - 120.0);
    verticalPositionSlider.value = [self overlayTopMargin];
    [verticalPositionSlider addTarget:self action:@selector(verticalPositionChanged:)
                      forControlEvents:UIControlEventValueChanged];
    [settingsCard addSubview:verticalPositionSlider];

    UIButton *verticalResetButton = [UIButton buttonWithType:UIButtonTypeSystem];
    verticalResetButton.frame = CGRectMake(cardWidth - 78, 192, 60, 32);
    verticalResetButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    verticalResetButton.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [verticalResetButton setTitle:@"Reset" forState:UIControlStateNormal];
    [verticalResetButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [verticalResetButton addTarget:self action:@selector(resetVerticalPosition:)
                  forControlEvents:UIControlEventTouchUpInside];
    [settingsCard addSubview:verticalResetButton];

    UILabel *creditsLabel = [[UILabel alloc] initWithFrame:CGRectMake(18, cardHeight - 68,
                                                                      cardWidth - 36, 54)];
    creditsLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    creditsLabel.text = @"Descriptions: External Item Descriptions\nby wofsauge and contributors · github.com/wofsauge/External-Item-Descriptions";
    creditsLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    creditsLabel.font = [UIFont systemFontOfSize:9.5 weight:UIFontWeightRegular];
    creditsLabel.numberOfLines = 3;
    creditsLabel.textAlignment = NSTextAlignmentCenter;
    [settingsCard addSubview:creditsLabel];

    CGFloat inventoryWidth = MIN(440, window.bounds.size.width - 30);
    CGFloat inventoryHeight = MIN(350, window.bounds.size.height - 24);
    UIView *inventoryCard = [[UIView alloc] initWithFrame:
        CGRectMake((window.bounds.size.width - inventoryWidth) * 0.5,
                   (window.bounds.size.height - inventoryHeight) * 0.5,
                   inventoryWidth, inventoryHeight)];
    inventoryCard.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    inventoryCard.backgroundColor = [UIColor colorWithWhite:0.025 alpha:0.96];
    inventoryCard.layer.cornerRadius = 14;
    inventoryCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
    inventoryCard.layer.borderWidth = 1;
    inventoryCard.tag = 0xE1D;
    inventoryCard.hidden = YES;

    UILabel *inventoryTitle = [[UILabel alloc] initWithFrame:
        CGRectMake(16, 8, inventoryWidth - 66, 32)];
    inventoryTitle.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    inventoryTitle.text = @"Inventory & Transformations";
    inventoryTitle.textColor = UIColor.whiteColor;
    inventoryTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [inventoryCard addSubview:inventoryTitle];

    UIButton *inventoryClose = [UIButton buttonWithType:UIButtonTypeSystem];
    inventoryClose.frame = CGRectMake(inventoryWidth - 48, 6, 38, 34);
    inventoryClose.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    inventoryClose.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [inventoryClose setTitle:@"×" forState:UIControlStateNormal];
    [inventoryClose setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [inventoryClose addTarget:self action:@selector(closeInventory:)
             forControlEvents:UIControlEventTouchUpInside];
    [inventoryCard addSubview:inventoryClose];

    UIScrollView *inventoryScroll = [[UIScrollView alloc] initWithFrame:
        CGRectMake(10, 43, inventoryWidth - 20, inventoryHeight - 53)];
    inventoryScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    inventoryScroll.alwaysBounceVertical = YES;
    inventoryScroll.showsVerticalScrollIndicator = YES;
    [inventoryCard addSubview:inventoryScroll];

    [root addSubview:panel];
    [root addSubview:diagnostics];
    [root addSubview:settingsButton];
    [root addSubview:inventoryButton];
#if EID_DEBUG_MENU
    [root addSubview:debugButton];
    self.debugButton = debugButton;
#endif
    [root addSubview:settingsCard];
    [root addSubview:inventoryCard];
#if EID_DEBUG_MENU
    [self setupDebugCardInRootView:root window:window];
#endif
    [window addSubview:root];
    self.rootView = root;
    self.panel = panel;
    self.itemIconView = itemIcon;
    self.label = label;
    self.diagnosticsLabel = diagnostics;
    self.settingsButton = settingsButton;
    self.settingsCard = settingsCard;
    self.inventoryButton = inventoryButton;
    self.inventoryCard = inventoryCard;
    self.inventoryScrollView = inventoryScroll;
    self.settingsLanguageButton = languageSelector;
    self.settingsPositionLabel = positionLabel;
    self.settingsVersionLabel = versionLabel;
    self.settingsPositionSlider = positionSlider;
    self.settingsVerticalPositionLabel = verticalPositionLabel;
    self.settingsVerticalPositionSlider = verticalPositionSlider;
    [self updateSettingsControls];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    [self attachOverlayIfNeeded];
    self.diagnosticsLabel.hidden = !self.diagnosticsEnabled;
    self.diagnosticsLabel.text = [NSString stringWithFormat:@" EID %@ | pickups %@\n %@",
                                  self.probe.executableUUID, self.lastPickups, self.probe.status];
    if (self.scanInProgress) return;
    self.scanInProgress = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<EIDPickupIdentity *> *pickups = [self.probe currentDescribablePickups];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.scanInProgress = NO;
            [self updateMenuModeForGameplay:self.probe.gameplayActive];
            BOOL paused = self.probe.gameplayActive && self.probe.pauseStateAvailable &&
                self.probe.paused;
            [self updatePauseInventoryForPaused:paused];
            NSString *progressSignature = [[EIDTransformationProgress shared]
                progressSignatureForPickups:pickups];
            BOOL progressChanged = ![progressSignature
                isEqualToString:self.transformationProgressSignature ?: @""];
            self.transformationProgressSignature = progressSignature;
            if (![pickups isEqualToArray:self.lastPickups] || progressChanged) {
                self.lastPickups = pickups;
                if (!self.menuMode && !paused && !self.selectedInventoryItem) {
                    [self renderPickups:pickups];
                }
                EIDLog(@"visible describable pickups: %@", pickups);
            }
        });
    });
}

- (void)updateMenuModeForGameplay:(BOOL)gameplayActive {
    if (gameplayActive) {
        self.consecutiveMenuScans = 0;
        if (!self.menuMode) return;
        self.menuMode = NO;
        self.settingsCard.hidden = YES;
        [self updateSettingsControls];
        EIDLog(@"game state: gameplay active; settings available only while paused");
        return;
    }
    if (self.consecutiveMenuScans < 12) self.consecutiveMenuScans++;
    if (self.consecutiveMenuScans < 12) return;
    self.settingsButton.hidden = NO;
    if (self.menuMode) return;
    self.menuMode = YES;
    self.lastPickups = @[];
    self.panel.alpha = 0;
    EIDLog(@"game state: menu detected; settings available");
}

- (void)updatePauseInventoryForPaused:(BOOL)paused {
    BOOL available = paused && self.probe.inventoryStateAvailable;
    self.inventoryButton.hidden = !available;
#if EID_DEBUG_MENU
    self.debugButton.hidden = !paused;
#endif
    self.settingsButton.hidden = !(self.menuMode || paused);
    if (!paused) {
        self.inventoryCard.hidden = YES;
#if EID_DEBUG_MENU
        self.debugCard.hidden = YES;
#endif
        self.inventorySignature = nil;
        if (!self.menuMode) self.settingsCard.hidden = YES;
        if (self.pauseUIActive) {
            self.selectedInventoryItem = nil;
            if (!self.menuMode) [self renderPickups:self.lastPickups];
            EIDLog(@"pause inventory hidden; gameplay resumed");
        }
    } else if (!self.inventoryCard.hidden) {
        [self rebuildInventoryContentsIfNeeded:NO];
    }
    if (paused && !self.pauseUIActive) {
        EIDLog(@"native pause detected; inventory and settings buttons available");
    }
    self.pauseUIActive = paused;
}

- (void)updateSettingsControls {
    NSString *languageName = [self.store displayNameForLanguageCode:self.store.languageCode];
    [self.settingsLanguageButton setTitle:
        [NSString stringWithFormat:@"%@ · %@  ▾", languageName, self.store.languageCode]
                                  forState:UIControlStateNormal];
    CGFloat position = [self overlayLeftMargin];
    self.settingsPositionSlider.value = position;
    self.settingsPositionLabel.text = [NSString stringWithFormat:@"Horizontal position: %.0f px", position];
    CGFloat verticalPosition = [self overlayTopMargin];
    self.settingsVerticalPositionSlider.value = verticalPosition;
    self.settingsVerticalPositionLabel.text = [NSString stringWithFormat:
        @"Vertical position: %.0f px", verticalPosition];
    NSString *appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *context = self.probe.paused ? @"Paused" :
        (self.probe.gameplayActive ? @"In game" : @"Menu");
    self.settingsVersionLabel.text = [NSString stringWithFormat:
        @"%@ · iOS %@ · dataset: %@ · not Repentance+",
        context, appVersion,
        self.store.descriptionDataSet];
}

- (UIViewController *)topViewControllerFrom:(UIViewController *)viewController {
    UIViewController *current = viewController;
    while (current.presentedViewController) current = current.presentedViewController;
    if ([current isKindOfClass:UINavigationController.class]) {
        return [self topViewControllerFrom:((UINavigationController *)current).visibleViewController];
    }
    if ([current isKindOfClass:UITabBarController.class]) {
        return [self topViewControllerFrom:((UITabBarController *)current).selectedViewController];
    }
    return current;
}

- (void)showLanguagePicker:(UIButton *)sender {
    UIWindow *window = [self gameWindow];
    UIViewController *presenter = [self topViewControllerFrom:window.rootViewController];
    if (!presenter) {
        EIDLog(@"language picker unavailable: no game view controller");
        return;
    }

    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Description Language"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSString *code in self.store.availableLanguageCodes) {
        NSString *name = [self.store displayNameForLanguageCode:code];
        NSString *checkmark = [code isEqualToString:self.store.languageCode] ? @"✓ " : @"";
        NSString *title = [NSString stringWithFormat:@"%@%@ · %@", checkmark, name, code];
        [picker addAction:[UIAlertAction actionWithTitle:title
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(__unused UIAlertAction *action) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            [self.store setLanguageCode:code];
            [self updateSettingsControls];
            EIDLog(@"description language changed to %@", code);
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
    UIPopoverPresentationController *popover = picker.popoverPresentationController;
    popover.sourceView = sender;
    popover.sourceRect = sender.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    [presenter presentViewController:picker animated:YES completion:nil];
}

- (NSString *)inventorySignatureForItems:(NSArray<EIDPickupIdentity *> *)items {
    NSMutableString *signature = [NSMutableString string];
    for (EIDPickupIdentity *item in items) {
        [signature appendFormat:@"%ld:%ld,", (long)item.variant, (long)item.subtype];
    }
    for (EIDPickupIdentity *item in self.probe.smeltedTrinketItems) {
        [signature appendFormat:@"s%ld,", (long)item.subtype];
    }
    EIDTransformationProgress *tracker = [EIDTransformationProgress shared];
    tracker.probe = self.probe;
    for (NSNumber *identifier in tracker.allTransformationIdentifiers) {
        [signature appendFormat:@"t%@=%ld,", identifier,
         (long)[tracker progressForTransformation:identifier.integerValue]];
    }
    [signature appendFormat:@"lang=%@", self.store.languageCode];
    return signature;
}

- (UIImage *)inventoryIconForIdentity:(EIDPickupIdentity *)identity {
    EIDDescription *description = [self.store descriptionForPickupVariant:identity.variant
                                                                    subtype:identity.subtype];
    UIImage *image = description.iconPath.length
        ? [UIImage imageWithContentsOfFile:description.iconPath] : nil;
    return image ?: [self pocketIconForVariant:identity.variant subtype:identity.subtype];
}

- (void)addInventoryHeading:(NSString *)title y:(CGFloat *)y width:(CGFloat)width {
    UILabel *heading = [[UILabel alloc] initWithFrame:CGRectMake(4, *y, width - 8, 24)];
    heading.text = title;
    heading.textColor = [UIColor colorWithWhite:0.70 alpha:1];
    heading.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    [self.inventoryScrollView addSubview:heading];
    *y += 25;
}

- (void)addInventoryIdentity:(EIDPickupIdentity *)identity y:(CGFloat *)y width:(CGFloat)width {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.frame = CGRectMake(2, *y, width - 4, 40);
    row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.095];
    row.layer.cornerRadius = 7;
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    row.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    row.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [row setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    row.imageView.contentMode = UIViewContentModeScaleAspectFit;
    UIButtonConfiguration *configuration = [UIButtonConfiguration plainButtonConfiguration];
    configuration.imagePlacement = NSDirectionalRectEdgeLeading;
    configuration.imagePadding = 10;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(5, 7, 5, 8);
    row.configuration = configuration;

    NSInteger shownSubtype = identity.variant == EIDPickupVariantTrinket
        ? (identity.subtype & 0x7fff) : identity.subtype;
    EIDDescription *description = [self.store descriptionForPickupVariant:identity.variant
                                                                    subtype:identity.subtype];
    NSString *name = description.name.length ? description.name
        : [NSString stringWithFormat:@"%@ %ld", [self kindNameForVariant:identity.variant],
           (long)shownSubtype];
    [row setTitle:[NSString stringWithFormat:@"%@  [%ld]", name, (long)shownSubtype]
         forState:UIControlStateNormal];
    [row setImage:[self inventoryIconForIdentity:identity] forState:UIControlStateNormal];
    row.accessibilityIdentifier = [NSString stringWithFormat:@"%ld:%ld",
                                   (long)identity.variant, (long)identity.subtype];
    [row addTarget:self action:@selector(selectInventoryIdentity:)
  forControlEvents:UIControlEventTouchUpInside];
    [self.inventoryScrollView addSubview:row];
    *y += 44;
}

- (void)rebuildInventoryContentsIfNeeded:(BOOL)force {
    NSArray<EIDPickupIdentity *> *items = [self.probe currentInventoryItems];
    NSString *signature = [self inventorySignatureForItems:items];
    if (!force && [signature isEqualToString:self.inventorySignature]) return;
    self.inventorySignature = signature;
    [self.inventoryScrollView.subviews makeObjectsPerformSelector:@selector(removeFromSuperview)];

    NSMutableArray<EIDPickupIdentity *> *collectibles = [NSMutableArray array];
    NSMutableArray<EIDPickupIdentity *> *trinkets = [NSMutableArray array];
    NSMutableArray<EIDPickupIdentity *> *pockets = [NSMutableArray array];
    for (EIDPickupIdentity *item in items) {
        if (item.variant == EIDPickupVariantCollectible) [collectibles addObject:item];
        else if (item.variant == EIDPickupVariantTrinket) [trinkets addObject:item];
        else [pockets addObject:item];
    }

    NSArray<EIDPickupIdentity *> *heldTrinkets = self.probe.heldTrinketItems ?: @[];
    NSArray<EIDPickupIdentity *> *smeltedTrinkets = self.probe.smeltedTrinketItems ?: @[];

    BOOL russian = [self.store.languageCode isEqualToString:@"ru"];
    CGFloat width = self.inventoryScrollView.bounds.size.width;
    CGFloat y = 0;
    NSMutableArray<NSDictionary *> *sections = [NSMutableArray array];
    if (collectibles.count) {
        [sections addObject:@{@"title": russian ? @"Предметы" : @"Collectibles", @"items": collectibles}];
    }
    if (smeltedTrinkets.count > 0 || heldTrinkets.count > 0) {
        if (heldTrinkets.count) {
            [sections addObject:@{@"title": russian ? @"Брелоки (экипированы)" : @"Trinkets (Held)", @"items": heldTrinkets}];
        }
        if (smeltedTrinkets.count) {
            [sections addObject:@{@"title": russian ? @"Проглоченные брелоки" : @"Smelted Trinkets", @"items": smeltedTrinkets}];
        }
    } else if (trinkets.count) {
        [sections addObject:@{@"title": russian ? @"Брелоки" : @"Trinkets", @"items": trinkets}];
    }
    if (pockets.count) {
        [sections addObject:@{@"title": russian ? @"Карты, руны и таблетки" : @"Cards, runes & pills",
                              @"items": pockets}];
    }
    for (NSDictionary *section in sections) {
        NSArray<EIDPickupIdentity *> *sectionItems = section[@"items"];
        if (!sectionItems.count) continue;
        [self addInventoryHeading:section[@"title"] y:&y width:width];
        for (EIDPickupIdentity *identity in sectionItems) {
            [self addInventoryIdentity:identity y:&y width:width];
        }
        y += 3;
    }

    EIDTransformationProgress *tracker = [EIDTransformationProgress shared];
    [self addInventoryHeading:(russian ? @"Трансформации" : @"Transformations")
                            y:&y width:width];
    for (NSNumber *identifier in tracker.allTransformationIdentifiers) {
        NSInteger transformation = identifier.integerValue;
        NSInteger progress = [tracker progressForTransformation:transformation];
        UILabel *row = [[UILabel alloc] initWithFrame:CGRectMake(2, y, width - 4, 30)];
        row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.075];
        row.layer.cornerRadius = 6;
        row.layer.masksToBounds = YES;
        row.textColor = UIColor.whiteColor;
        row.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
        row.text = [NSString stringWithFormat:@"  %@   %ld/%ld",
                    [tracker localizedNameForTransformation:transformation],
                    (long)progress, (long)tracker.required];
        [self.inventoryScrollView addSubview:row];
        y += 34;
    }
    self.inventoryScrollView.contentSize = CGSizeMake(width, y + 8);
    EIDLog(@"pause inventory rendered: %lu items, %lu transformations",
           (unsigned long)items.count,
           (unsigned long)tracker.allTransformationIdentifiers.count);
}

- (void)toggleInventory:(UIButton *)sender {
    (void)sender;
    if (!self.probe.paused || !self.probe.inventoryStateAvailable) return;
    self.inventoryCard.hidden = !self.inventoryCard.hidden;
    self.settingsCard.hidden = YES;
#if EID_DEBUG_MENU
    self.debugCard.hidden = YES;
#endif
    if (!self.inventoryCard.hidden) {
        [self rebuildInventoryContentsIfNeeded:YES];
        [self.rootView bringSubviewToFront:self.inventoryCard];
        self.panel.alpha = 0;
    }
}

- (void)closeInventory:(UIButton *)sender {
    (void)sender;
    self.inventoryCard.hidden = YES;
}

- (void)selectInventoryIdentity:(UIButton *)sender {
    NSArray<NSString *> *parts = [sender.accessibilityIdentifier componentsSeparatedByString:@":"];
    if (parts.count != 2) return;
    NSInteger variant = parts[0].integerValue;
    NSInteger subtype = parts[1].integerValue;
    if (variant <= 0 || subtype <= 0) return;
    EIDPickupIdentity *identity = [[EIDPickupIdentity alloc] initWithVariant:variant
                                                                    subtype:subtype];
    self.selectedInventoryItem = identity;
    self.inventoryCard.hidden = YES;
    [self renderPickups:@[identity]];
    EIDLog(@"pause inventory selected %@", identity);
}

- (void)toggleSettings:(UIButton *)sender {
    (void)sender;
    self.settingsCard.hidden = !self.settingsCard.hidden;
    if (!self.settingsCard.hidden) {
        self.inventoryCard.hidden = YES;
#if EID_DEBUG_MENU
        self.debugCard.hidden = YES;
#endif
        [self updateSettingsControls];
        [self.rootView bringSubviewToFront:self.settingsCard];
        self.panel.alpha = 0;
    }
    EIDLog(@"settings panel %@ (%@)", self.settingsCard.hidden ? @"closed" : @"opened",
           self.probe.paused ? @"paused" : (self.menuMode ? @"menu" : @"gameplay"));
}

- (void)closeSettings:(UIButton *)sender {
    (void)sender;
    self.settingsCard.hidden = YES;
}

- (void)positionChanged:(UISlider *)slider {
    CGFloat position = round(slider.value);
    slider.value = position;
    [[NSUserDefaults standardUserDefaults] setDouble:position forKey:EIDHorizontalPositionKey];
    self.settingsPositionLabel.text = [NSString stringWithFormat:@"Horizontal position: %.0f px", position];
    [self sizePanelForText];
    CGRect diagnosticsFrame = self.diagnosticsLabel.frame;
    diagnosticsFrame.origin.x = position;
    diagnosticsFrame.size.width = MAX(100, self.rootView.bounds.size.width - position - EIDOverlayRightMargin);
    self.diagnosticsLabel.frame = diagnosticsFrame;
}

- (void)verticalPositionChanged:(UISlider *)slider {
    CGFloat position = round(slider.value);
    slider.value = position;
    [[NSUserDefaults standardUserDefaults] setDouble:position forKey:EIDVerticalPositionKey];
    self.settingsVerticalPositionLabel.text = [NSString stringWithFormat:
        @"Vertical position: %.0f px", position];
    [self sizePanelForText];
}

- (void)resetPosition:(UIButton *)sender {
    (void)sender;
    self.settingsPositionSlider.value = EIDDefaultOverlayLeftMargin;
    [self positionChanged:self.settingsPositionSlider];
    EIDLog(@"overlay horizontal position reset to %.0f px", EIDDefaultOverlayLeftMargin);
}

- (void)resetVerticalPosition:(UIButton *)sender {
    (void)sender;
    self.settingsVerticalPositionSlider.value = EIDDefaultOverlayTopMargin;
    [self verticalPositionChanged:self.settingsVerticalPositionSlider];
    EIDLog(@"overlay vertical position reset to %.0f px", EIDDefaultOverlayTopMargin);
}

- (NSString *)kindNameForVariant:(NSInteger)variant {
    BOOL russian = [self.store.languageCode isEqualToString:@"ru"];
    if (variant == EIDPickupVariantTrinket) return russian ? @"Брелок" : @"Trinket";
    if (variant == EIDPickupVariantCard) return russian ? @"Карта / руна" : @"Card / rune";
    if (variant == EIDPickupVariantPill) return russian ? @"Таблетка" : @"Pill";
    if (variant == EIDPickupVariantHorsePill) return russian ? @"Большая таблетка" : @"Horse pill";
    if (variant == EIDPickupVariantDiceRoom) return russian ? @"Комната игральной кости" : @"Dice Room";
    if (variant == EIDPickupVariantSacrificeRoom) return russian ? @"Комната жертвоприношений" : @"Sacrifice Room";
    return russian ? @"Артефакт" : @"Collectible";
}

- (void)loadPocketArtworkIfNeeded {
    if (self.cardAtlasFrames) return;
    NSString *animationPath = EIDGameResourcePath(@"gfx/ui/ui_cardspills.anm2");
    NSString *atlasPath = EIDGameResourcePath(@"gfx/ui/ui_cardfronts.png");
    NSData *animationData = animationPath.length
        ? [NSData dataWithContentsOfFile:animationPath] : nil;
    EIDCardAtlasParser *delegate = [[EIDCardAtlasParser alloc] init];
    if (animationData.length) {
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:animationData];
        parser.delegate = delegate;
        if (![parser parse]) [delegate.frames removeAllObjects];
    }
    self.cardAtlasFrames = delegate.frames.copy ?: @[];
    self.cardAtlas = atlasPath.length ? [UIImage imageWithContentsOfFile:atlasPath] : nil;

    NSString *cardPath = EIDGameResourcePath(@"gfx/items/pick ups/pickup_017_card.png");
    NSString *pillPath = EIDGameResourcePath(@"gfx/items/pick ups/pickup_007_pill.png");
    self.genericCardIcon = cardPath.length ? [UIImage imageWithContentsOfFile:cardPath] : nil;
    UIImage *pillAtlas = pillPath.length ? [UIImage imageWithContentsOfFile:pillPath] : nil;
    if (pillAtlas.CGImage) {
        // Isaac's white-white pill is the 32x32 frame at (0, 32). Use one
        // stable icon for every identified normal and horse pill.
        CGRect whitePillFrame = CGRectMake(0, 32, 32, 32);
        CGImageRef cropped = CGImageCreateWithImageInRect(pillAtlas.CGImage, whitePillFrame);
        if (cropped) {
            self.genericPillIcon = [UIImage imageWithCGImage:cropped
                                                       scale:1
                                                 orientation:UIImageOrientationUp];
            CGImageRelease(cropped);
        }
    }
    EIDLog(@"pocket artwork loaded: %lu card frames, atlas %@, card fallback %@, pill fallback %@",
           (unsigned long)self.cardAtlasFrames.count,
           self.cardAtlas ? @"yes" : @"no", self.genericCardIcon ? @"yes" : @"no",
           self.genericPillIcon ? @"yes" : @"no");
}

- (UIImage *)pocketIconForVariant:(NSInteger)variant subtype:(NSInteger)subtype {
    if (variant != EIDPickupVariantCard && variant != EIDPickupVariantPill &&
        variant != EIDPickupVariantHorsePill) return nil;
    NSString *key = [NSString stringWithFormat:@"%ld:%ld", (long)variant, (long)subtype];
    id cached = self.pocketIconCache[key];
    if (cached) return cached == NSNull.null ? nil : cached;
    [self loadPocketArtworkIfNeeded];

    UIImage *image = nil;
    if (variant == EIDPickupVariantCard) {
        if (subtype > 0 && subtype < (NSInteger)self.cardAtlasFrames.count && self.cardAtlas.CGImage) {
            id frameValue = self.cardAtlasFrames[(NSUInteger)subtype];
            if ([frameValue isKindOfClass:NSValue.class]) {
                CGRect frame = [frameValue CGRectValue];
                CGRect imageBounds = CGRectMake(0, 0, CGImageGetWidth(self.cardAtlas.CGImage),
                                                 CGImageGetHeight(self.cardAtlas.CGImage));
                if (CGRectContainsRect(imageBounds, frame)) {
                    CGImageRef cropped = CGImageCreateWithImageInRect(self.cardAtlas.CGImage, frame);
                    if (cropped) {
                        image = [UIImage imageWithCGImage:cropped scale:1 orientation:UIImageOrientationUp];
                        CGImageRelease(cropped);
                    }
                }
            }
        }
        if (!image) image = self.genericCardIcon;
    } else {
        image = self.genericPillIcon;
    }
    self.pocketIconCache[key] = image ?: NSNull.null;
    return image;
}

static NSDictionary<NSNumber *, NSArray<NSNumber *> *> *EIDWeaponOverridesTable(void) {
    static NSDictionary *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @579: @[@52, @69, @118, @168, @229, @316, @329, @379, @394, @395, @397, @440, @556, @597], // Spirit Sword
            @168: @[@374, @429, @553, @572, @678], // Epic Fetus
            @678: @[@69, @229, @316, @329, @397, @410, @533, @572, @597], // C-Section
            @52:  @[@68, @118, @374, @401, @429, @444, @461, @572, @597, @637], // Dr. Fetus
            @114: @[@5, @69, @132, @221, @224, @316, @379, @401, @410, @459, @461, @462, @529, @532, @533, @572, @597], // Mom's Knife
            @118: @[@316, @379, @410, @440, @453, @461, @462, @524, @533, @540, @597], // Brimstone
            @395: @[@5, @69, @104, @233, @316, @329, @379, @397, @410, @453, @461, @524, @529, @532, @533, @540, @572, @597], // Tech X
            @68:  @[@410, @462, @524, @533, @540, @597], // Technology
            @329: @[@69, @222, @224, @316, @394, @397, @410, @532], // Ludovico
            @561: @[@330], // Almond Milk
        };
    });
    return table;
}

static NSArray<NSNumber *> *EIDAzazelOverriddenList(void) {
    static NSArray *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[@316, @379, @410, @440, @453, @461, @462, @524, @533, @540, @597];
    });
    return list;
}

static NSArray<NSNumber *> *EIDAzazelOverridingList(void) {
    static NSArray *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[@579, @168, @52, @114, @531];
    });
    return list;
}

- (NSString *)enrichDescription:(NSString *)originalDetail
                      forPickup:(EIDPickupIdentity *)pickup
                 displaySubtype:(NSInteger)displaySubtype {
    __block NSString *detail = originalDetail ?: @"";
    NSMutableSet<NSString *> *addedLines = [NSMutableSet set];
    void (^appendLine)(NSString *) = ^(NSString *line) {
        if (!line.length || [addedLines containsObject:line]) return;
        [addedLines addObject:line];
        if (detail.length == 0) {
            detail = line;
        } else {
            detail = [detail stringByAppendingFormat:@"#%@", line];
        }
    };

    NSArray<EIDPickupIdentity *> *inventory = [self.probe currentInventoryItems];
    NSInteger playerType = self.probe.primaryPlayerType;
    EIDPlayerStats *stats = self.probe.primaryPlayerStats;
    BOOL isRussian = [self.store.languageCode isEqualToString:@"ru"];

    NSMutableSet<NSNumber *> *heldCollectibles = [NSMutableSet set];
    for (EIDPickupIdentity *invItem in inventory) {
        if (invItem.variant == EIDPickupVariantCollectible) {
            [heldCollectibles addObject:@(invItem.subtype)];
        }
    }

    // 1. Consolation Prize (ID 644)
    if (pickup.variant == EIDPickupVariantCollectible && displaySubtype == 644) {
        if (stats != nil) {
            double speedScore = round(((stats.moveSpeed * 4.5) - 2.0) * 100.0) / 100.0;
            double fireRate = 30.0 / (MAX(0.0, (double)stats.maxFireDelay) + 1.0);
            double tearsScore = round(((pow(fireRate, 0.75) * 2.120391) - 2.0) * 100.0) / 100.0;
            double dmg = MAX(0.0, (double)stats.damage);
            double damageScore = round(((pow(dmg, 0.56) * 2.231179) - 2.0) * 100.0) / 100.0;
            double rangeScore = round((((stats.tearRange - 230.0) / 60.0) + 2.0) * 100.0) / 100.0;

            double scores[4] = { speedScore, tearsScore, damageScore, rangeScore };
            double minScore = scores[0];
            for (int i = 1; i < 4; ++i) {
                if (scores[i] < minScore) minScore = scores[i];
            }
            NSMutableArray<NSNumber *> *lowestStats = [NSMutableArray array];
            for (int i = 0; i < 4; ++i) {
                if (fabs(scores[i] - minScore) < 0.001) {
                    [lowestStats addObject:@(i)];
                }
            }

            int coins = stats.coins;
            int bombs = stats.bombs * 3;
            int keys = stats.keys * 3;
            int pScores[3] = { coins, bombs, keys };
            int minPickup = pScores[0];
            for (int i = 1; i < 3; ++i) {
                if (pScores[i] < minPickup) minPickup = pScores[i];
            }
            NSMutableArray<NSNumber *> *lowestPickups = [NSMutableArray array];
            for (int i = 0; i < 3; ++i) {
                if (pScores[i] == minPickup) {
                    [lowestPickups addObject:@(i)];
                }
            }

            for (NSNumber *sNum in lowestStats) {
                int s = sNum.intValue;
                NSString *statStr = nil;
                if (s == 0) statStr = isRussian ? @"↑ {{Speed}} +0.2 к скорости" : @"↑ {{Speed}} +0.2 Speed";
                else if (s == 1) statStr = isRussian ? @"↑ {{Tears}} +0.5 к скорострельности" : @"↑ {{Tears}} +0.5 Fire rate";
                else if (s == 2) statStr = isRussian ? @"↑ {{Damage}} +1 к урону" : @"↑ {{Damage}} +1 Damage";
                else if (s == 3) statStr = isRussian ? @"↑ {{Range}} +2.5 к дальности" : @"↑ {{Range}} +2.5 Range";
                if (lowestStats.count > 1) statStr = [statStr stringByAppendingString:@"?"];
                appendLine(statStr);
            }

            for (NSNumber *pNum in lowestPickups) {
                int p = pNum.intValue;
                NSString *pStr = nil;
                if (p == 0) pStr = isRussian ? @"{{Coin}} 3 монеты" : @"{{Coin}} 3 Coins";
                else if (p == 1) pStr = isRussian ? @"{{Bomb}} 1 бомба" : @"{{Bomb}} 1 Bomb";
                else if (p == 2) pStr = isRussian ? @"{{Key}} 1 ключ" : @"{{Key}} 1 Key";
                if (lowestPickups.count > 1) pStr = [pStr stringByAppendingString:@"?"];
                appendLine(pStr);
            }
        } else {
            appendLine(isRussian ? @"{{ArrowUp}} Даёт бонус к наименьшему стату + расходники" : @"{{ArrowUp}} Gives boost to lowest stat + pickups");
        }
    }

    // 2. Car Battery Synergy
    if ([heldCollectibles containsObject:@356]) {
        if (pickup.variant == EIDPickupVariantCollectible) {
            NSString *synergy = [self.store carBatterySynergyForActiveCollectibleID:displaySubtype];
            if (synergy.length > 0) {
                appendLine([NSString stringWithFormat:@"{{Collectible356}} %@", synergy]);
            }
        }
    } else if (pickup.variant == EIDPickupVariantCollectible && displaySubtype == 356) {
        for (NSNumber *heldId in heldCollectibles) {
            NSString *synergy = [self.store carBatterySynergyForActiveCollectibleID:heldId.integerValue];
            if (synergy.length > 0) {
                EIDDescription *heldDesc = [self.store descriptionForPickupVariant:EIDPickupVariantCollectible
                                                                            subtype:heldId.integerValue];
                NSString *heldName = heldDesc.name.length ? heldDesc.name : [NSString stringWithFormat:@"%ld", (long)heldId.integerValue];
                appendLine([NSString stringWithFormat:@"{{Collectible%ld}} %@: %@", (long)heldId.integerValue, heldName, synergy]);
            }
        }
    }

    // 3. Tarot Cloth Buff
    if ([heldCollectibles containsObject:@451]) {
        if (pickup.variant == EIDPickupVariantCard) {
            NSString *buff = [self.store tarotClothBuffForCardID:displaySubtype];
            if (buff.length > 0) {
                appendLine([NSString stringWithFormat:@"{{Collectible451}} %@", buff]);
            }
        }
    } else if (pickup.variant == EIDPickupVariantCollectible && displaySubtype == 451) {
        for (EIDPickupIdentity *invItem in inventory) {
            if (invItem.variant == EIDPickupVariantCard) {
                NSString *buff = [self.store tarotClothBuffForCardID:invItem.subtype];
                if (buff.length > 0) {
                    EIDDescription *cardDesc = [self.store descriptionForPickupVariant:EIDPickupVariantCard
                                                                               subtype:invItem.subtype];
                    NSString *cardName = cardDesc.name.length ? cardDesc.name : [NSString stringWithFormat:@"%ld", (long)invItem.subtype];
                    appendLine([NSString stringWithFormat:@"{{Card}} %@: %@", cardName, buff]);
                }
            }
        }
    }

    // 4. Weapon Override Warnings & Conflicts
    if (pickup.variant == EIDPickupVariantCollectible) {
        NSDictionary<NSNumber *, NSArray<NSNumber *> *> *overrideTable = EIDWeaponOverridesTable();
        BOOL isAzazel = (playerType == 7 || playerType == 25);
        if (isAzazel) {
            if ([EIDAzazelOverriddenList() containsObject:@(displaySubtype)]) {
                appendLine(isRussian ? @"{{Warning}} Переопределено: Сера Азазеля" : @"{{Warning}} Overridden by: Azazel's Brimstone");
            }
            if ([EIDAzazelOverridingList() containsObject:@(displaySubtype)]) {
                appendLine(isRussian ? @"{{Warning}} Переопределяет: Сера Азазеля" : @"{{Warning}} Overrides: Azazel's Brimstone");
            }
        }
        for (NSNumber *heldId in heldCollectibles) {
            NSArray<NSNumber *> *heldOverrides = overrideTable[heldId];
            if ([heldOverrides containsObject:@(displaySubtype)]) {
                EIDDescription *hDesc = [self.store descriptionForPickupVariant:EIDPickupVariantCollectible
                                                                            subtype:heldId.integerValue];
                NSString *hName = hDesc.name.length ? hDesc.name : [NSString stringWithFormat:@"%ld", (long)heldId.integerValue];
                NSString *warn = isRussian
                    ? [NSString stringWithFormat:@"{{Warning}} Переопределено: {{Collectible%ld}} %@", (long)heldId.integerValue, hName]
                    : [NSString stringWithFormat:@"{{Warning}} Overridden by: {{Collectible%ld}} %@", (long)heldId.integerValue, hName];
                appendLine(warn);
            }
            NSArray<NSNumber *> *thisOverrides = overrideTable[@(displaySubtype)];
            if ([thisOverrides containsObject:heldId]) {
                EIDDescription *hDesc = [self.store descriptionForPickupVariant:EIDPickupVariantCollectible
                                                                            subtype:heldId.integerValue];
                NSString *hName = hDesc.name.length ? hDesc.name : [NSString stringWithFormat:@"%ld", (long)heldId.integerValue];
                NSString *warn = isRussian
                    ? [NSString stringWithFormat:@"{{Warning}} Переопределяет: {{Collectible%ld}} %@", (long)heldId.integerValue, hName]
                    : [NSString stringWithFormat:@"{{Warning}} Overrides: {{Collectible%ld}} %@", (long)heldId.integerValue, hName];
                appendLine(warn);
            }
        }
    }

    // 5. Character-Specific Warnings (The Lost / Keeper)
    if (playerType == 10 || playerType == 31) { // The Lost / Tainted Lost
        if (pickup.variant == EIDPickupVariantCollectible) {
            if (displaySubtype == 126 || displaySubtype == 135 || displaySubtype == 186) {
                appendLine(isRussian ? @"{{Warning}} Убивает при использовании!" : @"{{Warning}} Kills on use!");
            } else if (displaySubtype == 475) {
                appendLine(isRussian ? @"{{Warning}} Убивает персонажа!" : @"{{Warning}} Kills the character!");
            }
        } else if (pickup.variant == EIDPickupVariantCard && displaySubtype == 46) {
            appendLine(isRussian ? @"{{Warning}} Убивает персонажа!" : @"{{Warning}} Kills the character!");
        }
    } else if (playerType == 14 || playerType == 33) { // Keeper / Tainted Keeper
        if (pickup.variant == EIDPickupVariantCollectible) {
            if (displaySubtype == 227) {
                appendLine(isRussian ? @"{{Warning}} Выпадает только 0-1 монета" : @"{{Warning}} Only drops 0-1 coins");
            } else if (displaySubtype == 135) {
                appendLine(isRussian ? @"{{Warning}} Даёт только 0-1 монету" : @"{{Warning}} Only pays out 0-1 coins");
            }
        } else if (pickup.variant == EIDPickupVariantTrinket && displaySubtype == 1) {
            appendLine(isRussian ? @"{{Warning}} Выпадает только 0-1 монета" : @"{{Warning}} Only drops 0-1 coins");
        }
    }

    return detail;
}

- (void)renderPickups:(NSArray<EIDPickupIdentity *> *)pickups {
    if (!pickups.count) {
        UIView *panel = self.panel;
        [UIView animateWithDuration:0.15 animations:^{
            panel.alpha = 0;
        } completion:^(BOOL finished) {
            if (!finished || panel.alpha > 0.01) return;
            self.itemIconView.image = nil;
            self.itemIconView.hidden = YES;
            self.label.text = nil;
            self.label.attributedText = nil;
        }];
        return;
    }
    [self.panel.layer removeAllAnimations];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    EIDDescription *displayItem = nil;
    NSUInteger shown = MIN(pickups.count, 1);
    for (NSUInteger index = 0; index < shown; ++index) {
        EIDPickupIdentity *pickup = pickups[index];
        NSInteger displaySubtype = pickup.variant == EIDPickupVariantTrinket
            ? (pickup.subtype & 0x7fff) : pickup.subtype;
        EIDDescription *item = [self.store descriptionForPickupVariant:pickup.variant
                                                                subtype:pickup.subtype];
        if (index == 0) displayItem = item;
        NSString *kind = [self kindNameForVariant:pickup.variant];
        NSString *name = item.name.length ? item.name
            : [NSString stringWithFormat:@"%@ %ld", kind, (long)displaySubtype];
        NSString *detail = item.detail.length ? item.detail
            : ([self.store.languageCode isEqualToString:@"ru"]
               ? @"Описание недоступно" : @"No description available");
        detail = [self enrichDescription:detail forPickup:pickup displaySubtype:displaySubtype];
        detail = [detail stringByReplacingOccurrencesOfString:@"#" withString:@"\n"];
        detail = [self renderMarkup:detail];
        [lines addObject:[NSString stringWithFormat:@"%@ · %@  [%ld]\n%@",
                          kind, name, (long)displaySubtype, detail]];
    }
    if (pickups.count > shown) {
        NSString *more = [self.store.languageCode isEqualToString:@"ru"] ? @"ещё объектов" : @"more pickups";
        [lines addObject:[NSString stringWithFormat:@"+ %lu %@",
                          (unsigned long)(pickups.count - shown), more]];
    }
    UIImage *itemImage = displayItem.iconPath.length
        ? [UIImage imageWithContentsOfFile:displayItem.iconPath] : nil;
    if (!itemImage) {
        EIDPickupIdentity *pickup = pickups.firstObject;
        itemImage = [self pocketIconForVariant:pickup.variant subtype:pickup.subtype];
    }
    self.itemIconView.image = itemImage;
    self.itemIconView.hidden = itemImage == nil;
    self.label.text = [lines componentsJoinedByString:@"\n\n"];
    [self sizePanelForText];
    [UIView animateWithDuration:0.15 animations:^{ self.panel.alpha = 1; }];
}

- (void)sizePanelForText {
    CGRect bounds = self.rootView.bounds;
    CGFloat leftMargin = [self overlayLeftMargin];
    CGFloat availableWidth = MAX(180, bounds.size.width - leftMargin - EIDOverlayRightMargin);
    CGFloat width = MIN(390, MAX(270, bounds.size.width * 0.42));
    width = MIN(width, availableWidth);
    CGFloat iconSpace = self.itemIconView.hidden ? 0 : EIDItemIconSize + EIDItemIconSpacing;
    CGFloat textWidth = MAX(120, width - iconSpace);
    CGFloat topMargin = [self overlayTopMargin];
    CGFloat maximumHeight = MAX(100, bounds.size.height - topMargin - 16);

    CGFloat fontSize = 10.5;
    CGSize textSize = CGSizeZero;
    do {
        self.label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
        textSize = [self.label sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
        fontSize -= 0.5;
    } while (textSize.height > maximumHeight && fontSize >= 7.5);

    // Very long imported descriptions can use more horizontal room, but are never
    // clipped to an arbitrary character or line count.
    if (textSize.height > maximumHeight && width < availableWidth) {
        width = MIN(availableWidth, MAX(width, bounds.size.width * 0.58));
        textWidth = MAX(120, width - iconSpace);
        textSize = [self.label sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
    }
    CGFloat height = MAX(EIDItemIconSize, textSize.height);
    self.panel.frame = CGRectMake(leftMargin, topMargin, width, height);
    self.itemIconView.frame = CGRectMake(0, 1, EIDItemIconSize, EIDItemIconSize);
    self.label.frame = CGRectMake(iconSpace, 0, textWidth, height);
    if (!self.loggedOverlayLayout) {
        self.loggedOverlayLayout = YES;
        EIDLog(@"overlay layout fixed at x %.0f y %.0f, icon origin x %.0f",
               self.panel.frame.origin.x,
               self.panel.frame.origin.y,
               self.panel.frame.origin.x + self.itemIconView.frame.origin.x);
    }
}

- (NSString *)renderMarkup:(NSString *)input {
    static NSDictionary<NSString *, NSString *> *symbols;
    static NSRegularExpression *pattern;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        symbols = @{
            @"Tears": @"💧", @"Damage": @"⚔", @"Range": @"↔", @"Shotspeed": @"➤",
            @"Luck": @"🍀", @"Speed": @"👟", @"Heart": @"♥", @"HalfHeart": @"♥",
            @"SoulHeart": @"♡", @"BlackHeart": @"🖤", @"EternalHeart": @"♡",
            @"HealingRed": @"♥", @"Coin": @"¢", @"Bomb": @"💣", @"Key": @"🔑",
            @"Battery": @"⚡", @"Timer": @"◷", @"Warning": @"⚠", @"Poison": @"☠",
            @"Rune": @"◇", @"Card": @"▣", @"AngelRoom": @"♢", @"DevilRoom": @"♠",
            @"TreasureRoom": @"★", @"Shop": @"$", @"Chargeable": @"⚡",
            @"CarBattery": @"🔋", @"TarotCloth": @"🔮"
        };
        pattern = [NSRegularExpression regularExpressionWithPattern:@"\\{\\{([^}]+)\\}\\}"
                                                             options:0 error:nil];
    });
    NSMutableString *output = [input mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [pattern matchesInString:input options:0
                                                                  range:NSMakeRange(0, input.length)];
    for (NSTextCheckingResult *match in matches.reverseObjectEnumerator) {
        NSString *token = [input substringWithRange:[match rangeAtIndex:1]];
        NSString *replacement = symbols[token];
        if (!replacement && [token hasPrefix:@"Collectible"]) {
            if ([token isEqualToString:@"Collectible356"]) replacement = @"🔋";
            else if ([token isEqualToString:@"Collectible451"]) replacement = @"🔮";
            else replacement = @"◆";
        }
        if (!replacement && [token hasPrefix:@"Color"]) replacement = @"";
        if (!replacement && [token hasPrefix:@"Blink"]) replacement = @"";
        if (!replacement && [token isEqualToString:@"CR"]) replacement = @"";
        if (!replacement) replacement = @"";
        [output replaceCharactersInRange:match.range withString:replacement];
    }
    return output;
}

- (void)showCollectibleID:(NSInteger)collectibleID {
    EIDPickupIdentity *pickup = [[EIDPickupIdentity alloc]
        initWithVariant:EIDPickupVariantCollectible subtype:collectibleID];
    dispatch_async(dispatch_get_main_queue(), ^{ [self renderPickups:@[pickup]]; });
}

- (void)setDiagnosticsEnabled:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_diagnosticsEnabled = enabled;
        self.diagnosticsLabel.hidden = !enabled;
    });
}

#if EID_DEBUG_MENU
- (void)setupDebugCardInRootView:(UIView *)root window:(UIWindow *)window {
    CGFloat cardWidth = MIN(440, window.bounds.size.width - 24);
    CGFloat cardHeight = MIN(360, window.bounds.size.height - 24);
    UIView *card = [[UIView alloc] initWithFrame:
        CGRectMake((window.bounds.size.width - cardWidth) * 0.5,
                   (window.bounds.size.height - cardHeight) * 0.5, cardWidth, cardHeight)];
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
        UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:0.96];
    card.layer.cornerRadius = 14;
    card.layer.borderColor = [UIColor colorWithRed:0.85 green:0.25 blue:0.2 alpha:0.65].CGColor;
    card.layer.borderWidth = 1.5;
    card.tag = 0xE1D;
    card.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, cardWidth - 66, 30)];
    title.text = @"🛠 EID Debug Console";
    title.textColor = [UIColor colorWithRed:1.0 green:0.4 blue:0.3 alpha:1.0];
    title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [card addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(cardWidth - 46, 6, 36, 32);
    closeBtn.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    [closeBtn setTitle:@"×" forState:UIControlStateNormal];
    [closeBtn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closeDebugMenu:) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:closeBtn];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(12, 40, cardWidth - 24, 38)];
    status.numberOfLines = 2;
    status.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightMedium];
    status.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.6 alpha:1.0];
    status.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    status.layer.cornerRadius = 6;
    status.layer.masksToBounds = YES;
    status.textAlignment = NSTextAlignmentCenter;
    status.text = @"Ready. Stand near a pedestal or pickup to test.";
    [card addSubview:status];
    self.debugStatusLabel = status;

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:
        CGRectMake(12, 82, cardWidth - 24, cardHeight - 88)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    scroll.showsVerticalScrollIndicator = YES;
    [card addSubview:scroll];
    self.debugScrollView = scroll;

    [self buildDebugControlsInScrollView:scroll width:cardWidth - 24];

    [root addSubview:card];
    self.debugCard = card;
}

- (UIButton *)createDebugButtonWithTitle:(NSString *)title action:(SEL)action frame:(CGRect)frame color:(UIColor *)color {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = color ?: [UIColor colorWithWhite:1 alpha:0.12];
    btn.layer.cornerRadius = 6;
    btn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    btn.layer.borderWidth = 1;
    btn.titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    btn.titleLabel.adjustsFontSizeToFitWidth = YES;
    btn.titleLabel.minimumScaleFactor = 0.8;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)buildDebugControlsInScrollView:(UIScrollView *)scroll width:(CGFloat)width {
    __block CGFloat y = 4;
    CGFloat colW = (width - 8) * 0.5;
    CGFloat btnH = 32;
    CGFloat space = 6;

    void (^addHeader)(NSString *) = ^(NSString *titleText) {
        UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(2, y, width - 4, 20)];
        hdr.text = titleText;
        hdr.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        hdr.textColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
        [scroll addSubview:hdr];
        y += 22;
    };

    // --- Section 1: Transform Pickup ---
    addHeader(@"🔮 TRANSFORM NEAREST PICKUP / PEDESTAL");

    UIColor *pedestalColor = [UIColor colorWithRed:0.25 green:0.18 blue:0.42 alpha:0.85];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Consolation Prize (644)"
                                                 action:@selector(debugTransformConsolationPrize:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pedestalColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Brimstone (118)"
                                                 action:@selector(debugTransformBrimstone:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pedestalColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"Mom's Knife (114)"
                                                 action:@selector(debugTransformMomsKnife:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pedestalColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Trisagion (678)"
                                                 action:@selector(debugTransformTrisagion:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pedestalColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"Car Battery (356)"
                                                 action:@selector(debugTransformCarBattery:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pedestalColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Tarot Cloth (451)"
                                                 action:@selector(debugTransformTarotCloth:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pedestalColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"Custom Item ID (1 - 732)... ➔"
                                                 action:@selector(debugTransformCustomItem:)
                                                  frame:CGRectMake(0, y, width, btnH)
                                                  color:[UIColor colorWithRed:0.32 green:0.2 blue:0.55 alpha:0.95]]];
    y += btnH + space + 8;

    // --- Section 2: Pocket Items & Pills ---
    addHeader(@"💊 POCKET ITEMS, PILLS & TRINKETS");

    UIColor *pillColor = [UIColor colorWithRed:0.18 green:0.32 blue:0.45 alpha:0.85];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Give Gulp! Pill"
                                                 action:@selector(debugGiveGulpPill:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pillColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Identify All Pills"
                                                 action:@selector(debugIdentifyAllPills:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pillColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"Cancer (39) + Gulp!"
                                                 action:@selector(debugSmeltCancer:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pillColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Curved Horn (35) + Gulp!"
                                                 action:@selector(debugSmeltCurvedHorn:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pillColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"The Sun (Card 19)"
                                                 action:@selector(debugGiveTheSun:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:pillColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"The Joker (Card 22)"
                                                 action:@selector(debugGiveTheJoker:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:pillColor]];
    y += btnH + space + 8;

    // --- Section 3: Player Stats & Resources ---
    addHeader(@"⚡ PLAYER STATS & RESOURCES");

    UIColor *statColor = [UIColor colorWithRed:0.2 green:0.38 blue:0.25 alpha:0.85];
    [scroll addSubview:[self createDebugButtonWithTitle:@"99 Coins, Bombs, Keys"
                                                 action:@selector(debugGiveConsumables:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:statColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"Heal / +6 Soul Hearts"
                                                 action:@selector(debugHealPlayer:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:statColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"+5.0 Damage"
                                                 action:@selector(debugAddDamage:)
                                                  frame:CGRectMake(0, y, colW, btnH)
                                                  color:statColor]];
    [scroll addSubview:[self createDebugButtonWithTitle:@"+2.0 Tears"
                                                 action:@selector(debugAddTears:)
                                                  frame:CGRectMake(colW + 8, y, colW, btnH)
                                                  color:statColor]];
    y += btnH + space;

    [scroll addSubview:[self createDebugButtonWithTitle:@"+0.3 Speed"
                                                 action:@selector(debugAddSpeed:)
                                                  frame:CGRectMake(0, y, width, btnH)
                                                  color:statColor]];
    y += btnH + space + 12;

    scroll.contentSize = CGSizeMake(width, y);
}

- (void)toggleDebugMenu:(UIButton *)sender {
    (void)sender;
    self.debugCard.hidden = !self.debugCard.hidden;
    if (!self.debugCard.hidden) {
        self.inventoryCard.hidden = YES;
        self.settingsCard.hidden = YES;
        [self updateDebugStatus];
        [self.rootView bringSubviewToFront:self.debugCard];
        self.panel.alpha = 0;
    }
}

- (void)closeDebugMenu:(UIButton *)sender {
    (void)sender;
    self.debugCard.hidden = YES;
}

- (void)updateDebugStatus {
    if (!self.debugStatusLabel) return;
    if (self.probe.nearestPickupAddress) {
        self.debugStatusLabel.text = [NSString stringWithFormat:
            @"Nearest Pickup at 0x%lx\nPlayer: active · ready for transformation",
            (unsigned long)self.probe.nearestPickupAddress];
    } else if (self.probe.lastPickupAddresses.count > 0) {
        self.debugStatusLabel.text = [NSString stringWithFormat:
            @"%lu pickups detected in room (nearest: none)\nStand close to an item to transform it",
            (unsigned long)self.probe.lastPickupAddresses.count];
    } else {
        self.debugStatusLabel.text = @"No pickups found in current room.\nEnter an item/boss/shop room first.";
    }
}

- (void)flashDebugMessage:(NSString *)msg success:(BOOL)success {
    if (!self.debugStatusLabel) return;
    self.debugStatusLabel.textColor = success
        ? [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0]
        : [UIColor colorWithRed:1.0 green:0.4 blue:0.4 alpha:1.0];
    self.debugStatusLabel.text = msg;
}

- (void)debugTransformConsolationPrize:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:644];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #644 (Consolation Prize)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformBrimstone:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:118];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #118 (Brimstone)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformMomsKnife:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:114];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #114 (Mom's Knife)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformTrisagion:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:678];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #678 (Trisagion)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformCarBattery:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:356];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #356 (Car Battery)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformTarotCloth:(id)sender {
    (void)sender;
    BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:451];
    [self flashDebugMessage:ok ? @"✓ Transformed nearest pedestal to #451 (Tarot Cloth)!"
                               : @"✗ Failed: No pedestal/pickup nearby to transform."
                    success:ok];
}

- (void)debugTransformCustomItem:(id)sender {
    (void)sender;
    UIWindow *window = [self gameWindow];
    UIViewController *presenter = [self topViewControllerFrom:window.rootViewController];
    if (!presenter) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Transform Nearest Pickup"
                                                                   message:@"Enter Collectible ID (1 - 732):"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"e.g. 644";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Transform" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *text = alert.textFields.firstObject.text;
        NSInteger itemID = text.integerValue;
        if (itemID >= 1 && itemID <= 732) {
            BOOL ok = [self.probe transformNearestPickupToVariant:EIDPickupVariantCollectible subtype:itemID];
            EIDDescription *desc = [self.store descriptionForPickupVariant:EIDPickupVariantCollectible subtype:itemID];
            NSString *name = desc.name.length ? desc.name : [NSString stringWithFormat:@"#%ld", (long)itemID];
            [self flashDebugMessage:ok ? [NSString stringWithFormat:@"✓ Transformed to #%ld (%@)!", (long)itemID, name]
                                       : @"✗ Failed: No pedestal/pickup nearby."
                            success:ok];
        } else {
            [self flashDebugMessage:@"✗ Invalid ID: must be between 1 and 732." success:NO];
        }
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)debugGiveGulpPill:(id)sender {
    (void)sender;
    BOOL ok = [self.probe giveGulpPillToPocket];
    [self flashDebugMessage:ok ? @"✓ Gave Gulp! pill to pocket slot 0! (Use pill in-game to swallow trinket)"
                               : @"✗ Failed to give Gulp! pill."
                    success:ok];
}

- (void)debugIdentifyAllPills:(id)sender {
    (void)sender;
    BOOL ok = [self.probe identifyAllPills];
    [self flashDebugMessage:ok ? @"✓ All 14 pill colors identified!"
                               : @"✗ Failed to identify pills."
                    success:ok];
}

- (void)debugSmeltCancer:(id)sender {
    (void)sender;
    BOOL ok = [self.probe smeltTrinketWithPill:39]; // 39 = Cancer
    [self flashDebugMessage:ok ? @"✓ Gave Cancer (#39) & Gulp! pill to pocket! Use pill to gulp it."
                               : @"✗ Failed to equip trinket/pill."
                    success:ok];
}

- (void)debugSmeltCurvedHorn:(id)sender {
    (void)sender;
    BOOL ok = [self.probe smeltTrinketWithPill:35]; // 35 = Curved Horn
    [self flashDebugMessage:ok ? @"✓ Gave Curved Horn (#35) & Gulp! pill to pocket! Use pill to gulp it."
                               : @"✗ Failed to equip trinket/pill."
                    success:ok];
}

- (void)debugGiveTheSun:(id)sender {
    (void)sender;
    BOOL ok = [self.probe giveCardToPocket:19]; // 19 = The Sun
    [self flashDebugMessage:ok ? @"✓ Gave Card #19 (The Sun) to pocket slot 0!"
                               : @"✗ Failed to give card."
                    success:ok];
}

- (void)debugGiveTheJoker:(id)sender {
    (void)sender;
    BOOL ok = [self.probe giveCardToPocket:22]; // 22 = The Joker
    [self flashDebugMessage:ok ? @"✓ Gave Card #22 (The Joker) to pocket slot 0!"
                               : @"✗ Failed to give card."
                    success:ok];
}

- (void)debugGiveConsumables:(id)sender {
    (void)sender;
    BOOL ok = [self.probe giveConsumablesCoins:99 bombs:99 keys:99];
    [self flashDebugMessage:ok ? @"✓ Set 99 Coins, 99 Bombs, 99 Keys!"
                               : @"✗ Failed to set consumables."
                    success:ok];
}

- (void)debugHealPlayer:(id)sender {
    (void)sender;
    BOOL ok = [self.probe healPlayer];
    [self flashDebugMessage:ok ? @"✓ Full health and +6 Soul Hearts granted!"
                               : @"✗ Failed to heal player."
                    success:ok];
}

- (void)debugAddDamage:(id)sender {
    (void)sender;
    BOOL ok = [self.probe addPlayerSpeed:0 damage:5.0f tears:0];
    [self flashDebugMessage:ok ? @"✓ Added +5.0 Damage! Consolation Prize prediction updated."
                               : @"✗ Failed to modify damage."
                    success:ok];
}

- (void)debugAddTears:(id)sender {
    (void)sender;
    BOOL ok = [self.probe addPlayerSpeed:0 damage:0 tears:2.0f];
    [self flashDebugMessage:ok ? @"✓ Boosted Tears (reduced fire delay by 2.0)!"
                               : @"✗ Failed to modify tears."
                    success:ok];
}

- (void)debugAddSpeed:(id)sender {
    (void)sender;
    BOOL ok = [self.probe addPlayerSpeed:0.3f damage:0 tears:0];
    [self flashDebugMessage:ok ? @"✓ Added +0.3 Speed!"
                               : @"✗ Failed to modify speed."
                    success:ok];
}
#endif
@end
