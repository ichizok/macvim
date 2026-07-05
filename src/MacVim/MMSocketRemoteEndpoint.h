/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

//
// Message layer over MMSocketChannel: implements MMRemoteEndpoint and carries
// the MMBackendEndpoint / MMAppEndpoint surfaces over a Unix-domain socket.
//
// Each frame is an envelope: [kind][opcode][correlationId][archived args].
// One-way methods map to ONEWAY frames; synchronous methods map to a REQUEST
// frame whose REPLY (matched by correlationId) is awaited by the caller.
//
// Inbound REQUEST/ONEWAY frames are queued on a process-global FIFO and served
// on the MAIN thread, either by a run-loop source (installed in the common
// modes) or — while a synchronous call is blocked waiting for its reply — by
// that caller itself, which pumps the FIFO.  The pump reproduces the
// reentrancy NSConnection provided in NSConnectionReplyMode: two peers that
// issue synchronous calls at the same time each serve the other instead of
// deadlocking.
//
// `incomingHandler` is invoked on the main thread for each inbound
// REQUEST/ONEWAY; integration code (MMAppController, MMBackend) wires it to
// the local target via +[MMSocketBackendProxy serveOpcode:...] /
// +[MMSocketAppProxy serveOpcode:...].  Set the handlers, then call -activate
// to start the flow of frames.
//

#import <Foundation/Foundation.h>
#import "MMRemoteEndpoint.h"

@class MMSocketChannel;

NS_ASSUME_NONNULL_BEGIN

@interface MMSocketRemoteEndpoint : NSObject <MMRemoteEndpoint>

- (instancetype)initWithChannel:(MMSocketChannel *)channel NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) MMSocketChannel *channel;

/// Invoked on the MAIN thread for each inbound REQUEST/ONEWAY.  For a
/// REQUEST, call `reply(result)` exactly once (result nil -> NSNull).  For a
/// ONEWAY, `reply` is a no-op.  Must be set before -activate and not changed
/// afterwards.
@property (nonatomic, copy, nullable)
        void (^incomingHandler)(uint32_t opcode, NSArray *args,
                                void (^reply)(id _Nullable result));

/// Start delivering frames.  Call once, after incomingHandler and any
/// invalidation handlers are in place; the peer's first frame may arrive
/// immediately (e.g. the backend's registration REQUEST).
- (void)activate;

/// Proxy the GUI uses to call the Vim backend (return-value surface).
- (id<MMBackendEndpoint>)backendProxy;

/// Proxy the Vim backend uses to call the GUI (return-value surface).
- (id<MMAppEndpoint>)appProxy;

// --- Used by the proxy objects -------------------------------------------

/// Fire-and-forget.
- (void)sendOnewayOpcode:(uint32_t)opcode args:(nullable NSArray *)args;

/// Send a REQUEST and block the calling thread until the REPLY arrives or the
/// wait times out (per -setReplyTimeout:; <= 0 waits forever).  A main-thread
/// caller serves queued inbound requests while it waits.  Returns the reply
/// value (or nil).
- (nullable id)sendRequestOpcode:(uint32_t)opcode
                            args:(nullable NSArray *)args;

@end


/// GUI-side proxy that turns MMBackendEndpoint calls into socket frames, and
/// (on the backend) decodes those frames back into MMBackendEndpoint calls.
@interface MMSocketBackendProxy : NSObject <MMBackendEndpoint>
- (instancetype)initWithEndpoint:(MMSocketRemoteEndpoint *)ep;
+ (void)serveOpcode:(uint32_t)opcode args:(NSArray *)args
             target:(id<MMBackendEndpoint>)target
              reply:(void (^)(id _Nullable result))reply;
@end


/// Backend-side proxy that turns MMAppEndpoint calls into socket frames, and
/// (on the GUI) decodes those frames back into MMAppEndpoint calls.  The GUI
/// target must also respond to -registerBackendWithPid:.
@interface MMSocketAppProxy : NSObject <MMAppEndpoint>
- (instancetype)initWithEndpoint:(MMSocketRemoteEndpoint *)ep;
+ (void)serveOpcode:(uint32_t)opcode args:(NSArray *)args
             target:(id)target
              reply:(void (^)(id _Nullable result))reply;
@end

NS_ASSUME_NONNULL_END
