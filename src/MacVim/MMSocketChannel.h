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
// Low-level framed, bidirectional Unix-domain-socket channel used as the
// transport for MacVim's frontend <-> backend IPC (replacing the deprecated
// NSConnection / Distributed Objects path).
//
// Wire framing is a 4-byte big-endian length prefix followed by that many
// payload bytes.  Inbound frames are delivered, one payload at a time, to
// `frameHandler` on a private serial queue (NOT the main thread) so that a
// caller which blocks the main thread waiting for a reply does not deadlock.
// `invalidationHandler` fires once on EOF or error.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The well-known filesystem path of the GUI's frontend rendezvous socket.
/// Computed identically by every MacVim process of the current user from the
/// per-user temp dir and a hash of the app bundle path (so distinct MacVim
/// installs do not collide and the path stays within sockaddr_un limits).
extern NSString *MMFrontendSocketPath(void);

@interface MMSocketChannel : NSObject

/// Called once per complete inbound frame, on the channel's private delivery
/// queue.  Set before -resume.
@property (nonatomic, copy, nullable) void (^frameHandler)(NSData *payload);

/// Called once when the peer disconnects or an unrecoverable error occurs,
/// on the channel's private delivery queue.
@property (nonatomic, copy, nullable) void (^invalidationHandler)(void);

/// Wrap an already-connected stream socket.  The receiver owns the fd and
/// closes it on invalidation.
- (instancetype)initWithFileDescriptor:(int)fd NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Connect to the Unix socket at `path`.  Returns nil on failure.
+ (nullable instancetype)channelByConnectingToPath:(NSString *)path;

/// Start delivering inbound frames.  Call after setting the handlers.
- (void)resume;

/// Enqueue one framed message.  Thread-safe; the actual write happens on a
/// private serial queue.
- (void)sendFrame:(NSData *)payload;

/// Block until every frame enqueued so far has been handed to the socket (or
/// the timeout expires; negative means wait forever).  Returns YES if all
/// pending writes completed.  Used to drain the channel before process exit
/// so the peer sees the final messages before EOF.
- (BOOL)flushWithTimeout:(NSTimeInterval)timeout;

/// Tear down: cancel sources, close the fd, fire no further handlers.
- (void)invalidate;

@property (nonatomic, readonly, getter=isValid) BOOL valid;

@end


//
// Accepts inbound connections on a Unix-domain socket bound to a filesystem
// path.  Used by the GUI as the rendezvous point that Vim children connect to.
//
@interface MMSocketListener : NSObject

/// Called for each accepted connection, on a private serial queue.
@property (nonatomic, copy, nullable) void (^acceptHandler)(MMSocketChannel *channel);

/// Bind+listen on `path` (a stale socket file at that path is removed first).
/// Returns nil on failure.
+ (nullable instancetype)listenerWithPath:(NSString *)path;

- (void)resume;
- (void)invalidate;

@property (nonatomic, readonly, copy) NSString *path;

@end

NS_ASSUME_NONNULL_END
