//
//  Trois-Bridging-Header.h
//  Bridging header for Objective-C interop
//

#import <Foundation/Foundation.h>
#import <mach/mach_error.h>

// TroisInjector XPC Protocol
@protocol TroisInjectorProtocol

- (void)injectBundle:(const char *)bundlePath inProcess:(pid_t)pid withReply:(void (^)(mach_error_t))reply;
- (void)pingWithReply:(void (^)(BOOL))reply;

@end
