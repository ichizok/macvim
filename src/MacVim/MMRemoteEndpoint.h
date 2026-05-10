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
// Transport-neutral protocols for the MacVim frontend <-> Vim backend IPC.
//
// The historical MMBackendProtocol / MMAppProtocol carry NSConnection-specific
// type qualifiers (oneway / in / out / bycopy / byref) so that NSDistantObject
// can marshal arguments efficiently. Those qualifiers are baked into the
// declarations and would force every caller to include DO-shaped semantics.
//
// The protocols below mirror the same surface without DO qualifiers so that
// call sites can be made transport-agnostic. The same Objective-C objects
// (MMBackend, MMAppController) adopt both the wire-protocol (with DO hints)
// and the endpoint-protocol (no hints); a future NSXPC transport can serve
// the same endpoint contract through a different adapter.
//

#import <Foundation/Foundation.h>

@class MMSelectionInfo;
@class MMEvalResult;


/// Surface that the MacVim frontend invokes against a Vim backend.
@protocol MMBackendEndpoint <NSObject>
- (void)processInput:(int)msgid data:(NSData *)data;
- (void)setDialogReturn:(id)obj;
- (NSString *)evaluateExpression:(NSString *)expr;
- (MMEvalResult *)evaluateExpressionCocoa:(NSString *)expr;
- (BOOL)hasSelectedText;
- (NSString *)selectedText;
- (void)insertOrReplaceSelectedText:(NSString *)text;
- (MMSelectionInfo *)mouseScreenposIsSelection:(int)row column:(int)column;
- (void)acknowledgeConnection;
@end


/// Surface that a Vim backend invokes against the MacVim frontend.
@protocol MMAppEndpoint <NSObject>
- (unsigned long)connectBackend:(id<MMBackendEndpoint>)backend pid:(int)pid;
- (void)processInput:(NSArray *)queue forIdentifier:(unsigned long)identifier;
- (NSArray *)serverList;
@end


/// Connection-level lifecycle abstracted over NSConnection / NSXPCConnection.
///
/// The DO adapter (MMDORemoteEndpoint) implements this against NSConnection;
/// future XPC transports implement the same protocol against NSXPCConnection.
/// Methods that have no XPC analogue (e.g. RunLoop modes) are no-ops in those
/// adapters, so call sites can stay transport-agnostic.
@protocol MMRemoteEndpoint <NSObject>

/// YES while the underlying connection is healthy.
- (BOOL)isValid;

/// Request and reply timeouts in seconds. -1 means "transport default".
- (NSTimeInterval)requestTimeout;
- (void)setRequestTimeout:(NSTimeInterval)seconds;
- (void)setReplyTimeout:(NSTimeInterval)seconds;

/// Subscribe to invalidation. The handler runs once when the peer
/// disappears (NSConnectionDidDieNotification on DO, invalidationHandler
/// on XPC). Returns an opaque token usable to unsubscribe; may be nil.
- (id)addInvalidationHandler:(void (^)(void))handler;
- (void)removeInvalidationHandler:(id)token;

/// DO-only: tells the connection to also process incoming requests in the
/// given runloop mode. No-op on transports that don't use NSRunLoop (XPC).
- (void)addRequestRunLoopMode:(NSString *)mode;
- (void)removeRequestRunLoopMode:(NSString *)mode;

@end
