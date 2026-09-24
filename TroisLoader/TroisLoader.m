//
//  TroisLoader.m
//  Loads into apps and hooks traffic light buttons
//

@import AppKit;
@import ObjectiveC;

#define TROIS_PREFS @"com.trois.app"

// Private classes we'll hook
@interface _NSThemeWidget : NSView
- (void)drawRect:(NSRect)dirtyRect;
@end

@interface _NSThemeCloseWidget : _NSThemeWidget
@end

@interface _NSThemeZoomWidget : _NSThemeWidget
@end

@interface _NSThemeMinimizeWidget : _NSThemeWidget
@end

@interface _NSThemeHelpWidget : _NSThemeWidget
@end

// Our hook implementations
static IMP originalCloseDrawRect = NULL;
static IMP originalMinimizeDrawRect = NULL;
static IMP originalZoomDrawRect = NULL;
static IMP originalHelpDrawRect = NULL;

// Filled on first draw and cleared on TroisThemeChanged. drawRect: runs on the main thread.
static NSUserDefaults *troisDefaults = nil;
static NSMutableDictionary<NSString *, id> *imageCache = nil;

static NSImage* loadButtonImage(NSString *buttonType, NSString *state) {
    if (!troisDefaults) troisDefaults = [[NSUserDefaults alloc] initWithSuiteName:TROIS_PREFS];
    if (!imageCache) imageCache = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@Button%@Image", buttonType, state];
    id cached = imageCache[key];
    if (cached) return cached == [NSNull null] ? nil : cached;

    NSString *path = [troisDefaults stringForKey:key];
    NSImage *image = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    imageCache[key] = image ?: [NSNull null];
    return image;
}

static void drawButtonImage(NSView *self, NSRect dirtyRect, NSString *buttonType, IMP originalIMP) {
    if (!troisDefaults) troisDefaults = [[NSUserDefaults alloc] initWithSuiteName:TROIS_PREFS];
    if (![troisDefaults boolForKey:@"troisEnabled"]) {
        if (originalIMP) {
            ((void (*)(id, SEL, NSRect))originalIMP)(self, @selector(drawRect:), dirtyRect);
        }
        return;
    }

    // Determine button state
    NSString *state = @"";
    BOOL isPressed = NO;
    BOOL isHovered = NO;

    // Try to detect state via private ivars or methods
    @try {
        if ([self respondsToSelector:@selector(isHighlighted)]) {
            isPressed = [(id)self isHighlighted];
        }
        if ([self respondsToSelector:NSSelectorFromString(@"_isMouseOver")]) {
            isHovered = [(id)self performSelector:NSSelectorFromString(@"_isMouseOver")];
        }
    } @catch (NSException *e) {}

    if (isPressed) state = @"Pressed";
    else if (isHovered) state = @"Hover";

    NSImage *image = loadButtonImage(buttonType, state);
    if (!image && state.length > 0) {
        image = loadButtonImage(buttonType, @"");  // Fall back to normal
    }

    if (image) {
        NSRect bounds = self.bounds;
        NSSize imageSize = image.size;

        // Center the image
        NSRect imageRect = NSMakeRect(
            (bounds.size.width - imageSize.width) / 2,
            (bounds.size.height - imageSize.height) / 2,
            imageSize.width,
            imageSize.height
        );

        [image drawInRect:imageRect
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0
           respectFlipped:YES
                    hints:nil];
    } else {
        // No custom image, draw original
        if (originalIMP) {
            ((void (*)(id, SEL, NSRect))originalIMP)(self, @selector(drawRect:), dirtyRect);
        }
    }
}

static void swizzledCloseDrawRect(id self, SEL _cmd, NSRect dirtyRect) {
    drawButtonImage(self, dirtyRect, @"close", originalCloseDrawRect);
}

static void swizzledMinimizeDrawRect(id self, SEL _cmd, NSRect dirtyRect) {
    drawButtonImage(self, dirtyRect, @"minimize", originalMinimizeDrawRect);
}

static void swizzledZoomDrawRect(id self, SEL _cmd, NSRect dirtyRect) {
    drawButtonImage(self, dirtyRect, @"zoom", originalZoomDrawRect);
}

static void swizzledHelpDrawRect(id self, SEL _cmd, NSRect dirtyRect) {
    drawButtonImage(self, dirtyRect, @"help", originalHelpDrawRect);
}

static void hookClass(Class cls, IMP *originalIMP, IMP newIMP) {
    if (!cls) return;

    Method method = class_getInstanceMethod(cls, @selector(drawRect:));
    if (method) {
        *originalIMP = method_setImplementation(method, newIMP);
        NSLog(@"TroisLoader: Hooked %@", NSStringFromClass(cls));
    }
}

@interface TroisLoader : NSObject
@end

@implementation TroisLoader

+ (void)load {
    // Skip certain apps
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    NSArray *blacklist = @[
        @"com.apple.loginwindow",
        @"com.apple.notificationcenterui",
        @"com.apple.dock",
        @"com.trois.app"  // Don't hook ourselves
    ];

    if ([blacklist containsObject:bundleId]) {
        return;
    }

    NSLog(@"TroisLoader: Loading into %@", bundleId);

    // Hook the traffic light button classes
    hookClass(NSClassFromString(@"_NSThemeCloseWidget"),
              &originalCloseDrawRect,
              (IMP)swizzledCloseDrawRect);

    hookClass(NSClassFromString(@"_NSThemeZoomWidget"),
              &originalZoomDrawRect,
              (IMP)swizzledZoomDrawRect);

    hookClass(NSClassFromString(@"_NSThemeMinimizeWidget"),
              &originalMinimizeDrawRect,
              (IMP)swizzledMinimizeDrawRect);

    hookClass(NSClassFromString(@"_NSThemeHelpWidget"),
              &originalHelpDrawRect,
              (IMP)swizzledHelpDrawRect);

    // Listen for theme changes
    [[NSDistributedNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(themeChanged:)
               name:@"TroisThemeChanged"
             object:nil];

    NSLog(@"TroisLoader: Hooks installed");
}

+ (void)themeChanged:(NSNotification *)note {
    [imageCache removeAllObjects];
    for (NSWindow *window in [NSApp windows]) {
        [window.contentView setNeedsDisplay:YES];
        // Force titlebar redraw
        @try {
            NSView *themeFrame = [window performSelector:NSSelectorFromString(@"_borderView")];
            [themeFrame setNeedsDisplay:YES];
        } @catch (NSException *e) {}
    }
}

@end
