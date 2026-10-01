//
//  NSObject+PrivateSwizzle.m
//  PlayTools
//
//  Created by siri on 06.10.2021.
//

#import "NSObject+Swizzle.h"
#import <objc/runtime.h>
#import "CoreGraphics/CoreGraphics.h"
#import "UIKit/UIKit.h"
#import <PlayTools/PlayTools-Swift.h>
#import "PTFakeMetaTouch.h"
#import <VideoSubscriberAccount/VideoSubscriberAccount.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>

__attribute__((visibility("hidden")))
@interface PTSwizzleLoader : NSObject
@end

@implementation NSObject (Swizzle)

- (void) swizzleInstanceMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    // Add selector if it doesn't exist, implement append with method
    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod)) ) {
        // Replace class instance method, added if selector not exist
        // For class cluster, it always adds new selector here
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
        
    } else {
        // SwizzleMethod maybe belongs to super
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

- (void) swizzleExchangeMethod:(SEL)origSelector withMethod:(SEL)newSelector
{
    Class cls = [self class];
    // If current class doesn't exist selector, then get super
    Method originalMethod = class_getInstanceMethod(cls, origSelector);
    Method swizzledMethod = class_getInstanceMethod(cls, newSelector);
    
    method_exchangeImplementations(originalMethod, swizzledMethod);
}

+ (void) swizzleClassMethod:(SEL)origSelector withMethod:(SEL)newSelector {
    Class cls = object_getClass((id)self);
    Method originalMethod = class_getClassMethod(cls, origSelector);
    Method swizzledMethod = class_getClassMethod(cls, newSelector);

    if (class_addMethod(cls,
                        origSelector,
                        method_getImplementation(swizzledMethod),
                        method_getTypeEncoding(swizzledMethod))) {
        class_replaceMethod(cls,
                            newSelector,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        class_replaceMethod(cls,
                            newSelector,
                            class_replaceMethod(cls,
                                                origSelector,
                                                method_getImplementation(swizzledMethod),
                                                method_getTypeEncoding(swizzledMethod)),
                            method_getTypeEncoding(originalMethod));
    }
}

- (BOOL) hook_prefersPointerLocked {
    return false;
}

- (CGRect) hook_frameDefault {
    return [PlayScreen frameDefault:[self hook_frameDefault]];
}

- (CGRect) hook_boundsDefault {
    return [PlayScreen boundsDefault:[self hook_boundsDefault]];
}

- (CGRect) hook_nativeBoundsDefault {
    return [PlayScreen nativeBoundsDefault:[self hook_nativeBoundsDefault]];
}

- (CGSize) hook_sizeDelfault {
    return [PlayScreen sizeAspectRatioDefault:[self hook_sizeDelfault]];
}


- (CGRect) hook_frame {
    return [PlayScreen frame:[self hook_frame]];
}

- (CGRect) hook_bounds {
    return [PlayScreen bounds:[self hook_bounds]];
}

- (CGRect) hook_nativeBounds {
    return [PlayScreen nativeBounds:[self hook_nativeBounds]];
}

- (CGSize) hook_size {
    return [PlayScreen sizeAspectRatio:[self hook_size]];
}



- (long long) hook_orientation {
    return 0;
}

- (double) hook_nativeScale {
    return [[PlaySettings shared] customScaler];
}

- (double) hook_scale {
    // Return rounded value of [[PlaySettings shared] customScaler]
    // Even though it is a double return, this will only accept .0 value or apps will crash
    return round([[PlaySettings shared] customScaler]);
}

- (double) get_default_height {
    return [[UIScreen mainScreen] bounds].size.height;
    
}
- (double) get_default_width {
    return [[UIScreen mainScreen] bounds].size.width;
    
}

- (CGRect) hook_boundsResizable {
    return [PlayScreen boundsResizable:[self hook_boundsResizable]];
}

- (BOOL) hook_requiresFullScreen {
    return NO;
}

- (void) hook_setCurrentSubscription:(VSSubscription *)currentSubscription {
    // do nothing
}

- (NSString *)hook_stringByReplacingOccurrencesOfRegularExpressionPattern:(NSString *)pattern
                                                             withTemplate:(NSString *)template
                                                                  options:(NSRegularExpressionOptions)options
                                                                    range:(NSRange)range {
    // If the string is empty, return immediately to prevent a range out-of-bounds error.
    if ([(NSString*)self isEqualToString:@""]) {
        return @"";
    }
    return [self hook_stringByReplacingOccurrencesOfRegularExpressionPattern:pattern
                                                                withTemplate:template
                                                                     options:options
                                                                       range:range];
}

- (void)hook_requestRecordPermission:(void (^)(BOOL))response {
    BOOL granted = [[AVAudioSession sharedInstance] recordPermission] == AVAudioSessionRecordPermissionGranted;
    if (granted) {
        response(granted);
    } else {
        [self hook_requestRecordPermission:response];
    }
}

- (instancetype)hook_CMMotionManager_init {
    CMMotionManager *motionManager = (CMMotionManager *)[self hook_CMMotionManager_init];
    // The default update interval is 0, which may lead to excessive CPU usage
    motionManager.accelerometerUpdateInterval = 0.01;
    motionManager.deviceMotionUpdateInterval = 0.01;
    motionManager.gyroUpdateInterval = 0.01;
    return motionManager;
}

+ (GCMouse *)hook_GCMouse_current {
    return nil;
}

+ (NSArray *)hook_GCMouse_mice {
    return @[];
}

// Hide GCKeyboard from the app so keyboard-as-controller emulation does not flip game UI
+ (GCKeyboard *)hook_GCKeyboard_coalescedKeyboard {
    return nil;
}

// Unity's UnityView feeds hardware keys to the game through UIKeyCommand; expose none when the keyboard is hidden
- (NSArray<UIKeyCommand *> *)hook_UnityView_keyCommands {
    return @[];
}

// Controller emulation mapping: feed Apple's emulated controller PlayCover's key layout (Apple's mapping if none)
- (void)hook_GCKeyboardAndMouseEmulatedController_remapControlsWith:(NSDictionary *)mapping {
    if (![mapping isKindOfClass:[NSDictionary class]]) {
        [self hook_GCKeyboardAndMouseEmulatedController_remapControlsWith:mapping];
        return;
    }
    [EmulatedControllerRemap rememberAppleMapping:mapping forController:self];
    [self hook_GCKeyboardAndMouseEmulatedController_remapControlsWith:[EmulatedControllerRemap mergedMapping:mapping]];
}

+ (void)hook_Unity_KeyboardDelegate_Initialize {
    @try {
        [self hook_Unity_KeyboardDelegate_Initialize];
    }
    @catch (NSException *exception) {
        NSLog(@"Caught exception: %@, reason: %@", exception.name, exception.reason);
    }
}

// Hook for UIUserInterfaceIdiom

// - (long long) hook_userInterfaceIdiom {
//     return UIUserInterfaceIdiomPad;
// }

bool menuWasCreated = false;
- (id) initWithRootMenuHook:(id)rootMenu {
    self = [self initWithRootMenuHook:rootMenu];
    if (!menuWasCreated) {
        [PlayCover initMenuWithMenu: self];
        menuWasCreated = TRUE;
    }
    return self;
}

@end

/*
 This class only exists to apply swizzles from the +load of a class that won't have any categories/extensions. The reason
 for not doing this in a C module initializer is that obj-c initialization happens before any __attribute__((constructor))
 is called. This way we can guarantee the hooks will be applied before [PlayCover launch] is called (in PlayLoader.m).
 
 Side note:
 While adding method replacements to NSObject does work, I'm not certain this doesn't (or won't) have any side effects. The
 way Apple does method swizzling internally is by creating a category of the swizzled class and adding the replacements there.
 This keeps all those replacements "local" to that class. Example:
 
 '''
 @interface FBSSceneSettings (Swizzle)
 -(CGRect) hook_frame {
    ...
 }
 @end
 
 Somewhere else:
 swizzle(FBSSceneSettings.class, @selector(frame), @selector(hook_frame);
 '''
 
 However, doing this would require generating @interface declarations (either with class-dump or by hand) which would add a lot
 of code and complexity. I'm not sure this trade-off is "worth it", at least at the time of writing.
 */

// Controller emulation mapping: GameControllerUI may load after +load, so this is retried until the class exists;
// on an unexpected signature it logs once and leaves Apple's behaviour untouched
static NSString *const kEmulatedControllerClassName = @"GCKeyboardAndMouseEmulatedController";
static const char *const kRemapControlsTypeEncoding = "v24@0:8@16";
static BOOL isEmulatedControllerRemapHookInstalled = NO;

static void installEmulatedControllerRemapHookIfNeeded(void) {
    static BOOL hasFoundClass = NO;
    if (hasFoundClass) return;
    Class emulatedControllerClass = NSClassFromString(kEmulatedControllerClassName);
    if (!emulatedControllerClass) return;
    hasFoundClass = YES;

    SEL remapSelector = NSSelectorFromString(@"remapControlsWith:");
    Method remapMethod = class_getInstanceMethod(emulatedControllerClass, remapSelector);
    const char *typeEncoding = remapMethod ? method_getTypeEncoding(remapMethod) : NULL;
    if (!typeEncoding || strcmp(typeEncoding, kRemapControlsTypeEncoding) != 0) {
        NSLog(@"[PlayTools] Controller emulation mapping disabled: unexpected -[%@ remapControlsWith:] (%s)",
              kEmulatedControllerClassName, typeEncoding ? typeEncoding : "missing");
        return;
    }
    [emulatedControllerClass swizzleInstanceMethod:remapSelector
                                        withMethod:@selector(hook_GCKeyboardAndMouseEmulatedController_remapControlsWith:)];
    isEmulatedControllerRemapHookInstalled = YES;
    [EmulatedControllerRemap hookDidInstall];
}

// Keep running in background: UINSWindowStateController requests scene background when -[NSWindow isOnActiveSpace]
// is NO (window on another Space), so the hook makes it always report YES; App Nap throttles invisible apps,
// so an activity is held to keep the game running at full speed.
// Side effect: AppKit sees every window of the game as on the active Space (activating the app may not switch Space).
@interface NSObject (KeepRunningInBackground)
- (BOOL)hook_NSWindow_isOnActiveSpace;
@end

@implementation NSObject (KeepRunningInBackground)
- (BOOL)hook_NSWindow_isOnActiveSpace {
    return YES;
}
@end

static const char *const kIsOnActiveSpaceTypeEncoding = "B16@0:8";
static id<NSObject> keepRunningInBackgroundActivityToken = nil;

static void installKeepRunningInBackgroundHooksIfNeeded(void) {
    static BOOL isInstalled = NO;
    if (isInstalled || ![[PlaySettings shared] keepRunningInBackground]) return;
    Class windowClass = objc_getClass("NSWindow");
    if (!windowClass) return; // class may load late; the delayed retry covers it
    isInstalled = YES;

    SEL selector = NSSelectorFromString(@"isOnActiveSpace");
    Method method = class_getInstanceMethod(windowClass, selector);
    const char *typeEncoding = method ? method_getTypeEncoding(method) : NULL;
    if (!typeEncoding || strcmp(typeEncoding, kIsOnActiveSpaceTypeEncoding) != 0) {
        NSLog(@"[PlayTools] Keep running in background disabled: unexpected -[NSWindow isOnActiveSpace] (%s)",
              typeEncoding ? typeEncoding : "missing");
        return;
    }
    [windowClass swizzleInstanceMethod:selector
                            withMethod:@selector(hook_NSWindow_isOnActiveSpace)];
}

static void startKeepRunningInBackgroundActivityIfNeeded(void) {
    if (keepRunningInBackgroundActivityToken || ![[PlaySettings shared] keepRunningInBackground]) return;
    // Both options are in the iOS SDK (iOS 7+), so no availability guard is needed
    NSActivityOptions options = NSActivityUserInitiatedAllowingIdleSystemSleep | NSActivityLatencyCritical;
    keepRunningInBackgroundActivityToken = [[NSProcessInfo processInfo] beginActivityWithOptions:options
                                                                                           reason:@"PlayTools keep running in background"];
}

@implementation PTSwizzleLoader
+ (void)load {
    // This might need refactor soon
    if(@available(iOS 16.3, *)) {
        if ([[PlaySettings shared] resizableWindow]) {
            [objc_getClass("_UIApplicationInfoParser") swizzleInstanceMethod:NSSelectorFromString(@"requiresFullScreen") withMethod:@selector(hook_requiresFullScreen)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsResizable)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
            [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
        }
        else if ([[PlaySettings shared] adaptiveDisplay]) {
            // This is an experimental fix
            if ([[PlaySettings shared] inverseScreenValues]) {
                // This lines set External Scene settings and other IOS10 Runtime services by swizzling
                // In Sonoma 14.1 betas, frame method seems to be moved to FBSSceneSettingsCore
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsDefault)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_sizeDelfault)];
                
                // Fixes Apple mess at MacOS 13.2
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBoundsDefault)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
            } else {
                // This acutally runs when adaptiveDisplay is normally triggered
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frame)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frame)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_bounds)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_size)];
                
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBounds)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];   
            }
        }
        else {
            if ([[PlaySettings shared] windowFixMethod] == 1) {
                // do nothing:tm:
            }
            else {
                CGFloat newValueW = (CGFloat) [self get_default_width];
                [[PlaySettings shared] setValue:@(newValueW) forKey:@"windowSizeWidth"];
                
                CGFloat newValueH = (CGFloat)[self get_default_height];
                [[PlaySettings shared] setValue:@(newValueH) forKey:@"windowSizeHeight"];
                if (![[PlaySettings shared] inverseScreenValues]) {
                    if(@available(iOS 17.1, *))
                        [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                    else
                        [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frameDefault)];
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_boundsDefault)];
                    [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_sizeDelfault)];
                }
                [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(orientation) withMethod:@selector(hook_orientation)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeBounds) withMethod:@selector(hook_nativeBoundsDefault)];
                
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(nativeScale) withMethod:@selector(hook_nativeScale)];
                [objc_getClass("UIScreen") swizzleInstanceMethod:@selector(scale) withMethod:@selector(hook_scale)];
            }
        }
    } 
    else {
        if ([[PlaySettings shared] adaptiveDisplay]) {
                if(@available(iOS 17.1, *))
                    [objc_getClass("FBSSceneSettingsCore") swizzleExchangeMethod:@selector(frame) withMethod:@selector(hook_frame)];
                else
                    [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(frame) withMethod:@selector(hook_frame)];
                [objc_getClass("FBSSceneSettings") swizzleInstanceMethod:@selector(bounds) withMethod:@selector(hook_bounds)];
                [objc_getClass("FBSDisplayMode") swizzleInstanceMethod:@selector(size) withMethod:@selector(hook_size)];
            }
    }
    
    [objc_getClass("_UIMenuBuilder") swizzleInstanceMethod:sel_getUid("initWithRootMenu:") withMethod:@selector(initWithRootMenuHook:)];
    [objc_getClass("IOSViewController") swizzleInstanceMethod:@selector(prefersPointerLocked) withMethod:@selector(hook_prefersPointerLocked)];
    // Set idiom to iPad
    // [objc_getClass("UIDevice") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];
    // [objc_getClass("UITraitCollection") swizzleInstanceMethod:@selector(userInterfaceIdiom) withMethod:@selector(hook_userInterfaceIdiom)];

    [objc_getClass("VSSubscriptionRegistrationCenter") swizzleInstanceMethod:@selector(setCurrentSubscription:) withMethod:@selector(hook_setCurrentSubscription:)];

    if (PlayInfo.isUnrealEngine) {
        // Fix NSRegularExpression crash when system language is set to Chinese
        CFStringEncoding encoding = CFStringGetSystemEncoding();
        if (encoding == kCFStringEncodingMacChineseSimp || encoding == kCFStringEncodingMacChineseTrad) {
            SEL origSelector = NSSelectorFromString(@"_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:");
            SEL newSelector = @selector(hook_stringByReplacingOccurrencesOfRegularExpressionPattern:withTemplate:options:range:);
            [objc_getClass("NSString") swizzleInstanceMethod:origSelector withMethod:newSelector];
        }
    }

    if ([[PlaySettings shared] checkMicPermissionSync]) {
        [objc_getClass("AVAudioSession") swizzleInstanceMethod:@selector(requestRecordPermission:) withMethod:@selector(hook_requestRecordPermission:)];
    }

    if ([[PlaySettings shared] limitMotionUpdateFrequency]) {
        [objc_getClass("CMMotionManager") swizzleInstanceMethod:@selector(init) withMethod:@selector(hook_CMMotionManager_init)];
    }

    if (([[PlaySettings shared] disableBuiltinMouse])) {
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(current) withMethod:@selector(hook_GCMouse_current)];
        [objc_getClass("GCMouse") swizzleClassMethod:@selector(mice) withMethod:@selector(hook_GCMouse_mice)];
    }

    // Hide GCKeyboard from the app so keyboard-as-controller emulation does not flip game UI
    if (([[PlaySettings shared] disableBuiltinKeyboard])) {
        [objc_getClass("GCKeyboard") swizzleClassMethod:@selector(coalescedKeyboard) withMethod:@selector(hook_GCKeyboard_coalescedKeyboard)];
    }

    // Keep running in background: no-op unless the setting is on
    installKeepRunningInBackgroundHooksIfNeeded();
    startKeepRunningInBackgroundActivityIfNeeded();

    // Controller emulation mapping: file-driven (no-op without PlayCover's file), so always installed
    installEmulatedControllerRemapHookIfNeeded();
    [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *notification) {
        installEmulatedControllerRemapHookIfNeeded();
        // Controller emulation mapping: a controller remapped by Apple before it was listed missed the late reload
        if (isEmulatedControllerRemapHookInstalled) {
            [EmulatedControllerRemap reloadControllers];
        }
    }];

    // Delay a frame to wait for some frameworks (such as UnityFramework) to load
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.01 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([[PlaySettings shared] ignoreUnityKeyboardInitializationError]) {
            [objc_getClass("KeyboardDelegate") swizzleClassMethod:NSSelectorFromString(@"Initialize") withMethod:@selector(hook_Unity_KeyboardDelegate_Initialize)];
        }
        // Also block the UIKeyCommand path UnityView uses to receive hardware keys (nil class on non-Unity apps is a no-op)
        if ([[PlaySettings shared] disableBuiltinKeyboard]) {
            [objc_getClass("UnityView") swizzleInstanceMethod:@selector(keyCommands) withMethod:@selector(hook_UnityView_keyCommands)];
        }
        // Controller emulation mapping: retry once GameControllerUI had a frame to load
        installEmulatedControllerRemapHookIfNeeded();
        // Keep running in background: retry once AppKit's NSWindow class is available
        installKeepRunningInBackgroundHooksIfNeeded();
    });
}

@end
