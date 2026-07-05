/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMSocketRemoteEndpoint.h"
#import "MMSocketChannel.h"
#import "MMEvalResult.h"
#import "MMSelectionInfo.h"
#import "MacVim.h"          // ASLog*

#import <libkern/OSByteOrder.h>

// Envelope kinds.
enum { MMFrameOneway = 0, MMFrameRequest = 1, MMFrameReply = 2 };

// Opcodes.  Backend-directed (GUI -> Vim) mirror MMBackendEndpoint;
// app-directed (Vim -> GUI) mirror MMAppEndpoint.
enum {
    // MMBackendEndpoint
    MMOpProcessInputData = 1,
    MMOpSetDialogReturn,
    MMOpEvaluateExpression,
    MMOpEvaluateExpressionCocoa,
    MMOpHasSelectedText,
    MMOpSelectedText,
    MMOpInsertOrReplaceSelectedText,
    MMOpMouseScreenposIsSelection,
    MMOpAcknowledgeConnection,
    // MMAppEndpoint
    MMOpRegisterBackend = 100,
    MMOpProcessInputForIdentifier,
    MMOpServerList,
};

static NSSet *MMAllowedArgClasses(void)
{
    static NSSet *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[NSSet setWithObjects:
              [NSArray class], [NSDictionary class], [NSString class],
              [NSNumber class], [NSData class], [NSNull class],
              [MMEvalResult class], [MMSelectionInfo class], nil] retain];
    });
    return s;
}

static inline id MMBox(id v) { return v ? v : (id)[NSNull null]; }
static inline id MMUnbox(id v) { return (v == [NSNull null]) ? nil : v; }

// Archive/unarchive the argument array.  Uses NSSecureCoding on 10.13+ (the
// supported floor for the socket transport); falls back to the legacy archiver
// when built against an older SDK so the shared sources still compile.
static NSData *MMArchiveArgs(NSArray *args)
{
    args = args ?: @[];
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_13
    if (AVAILABLE_MAC_OS(10, 13)) {
        NSError *err = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:args
                                         requiringSecureCoding:YES error:&err];
        if (!d) { ASLogErr(@"archive failed: %@", err); d = [NSData data]; }
        return d;
    }
#endif
    return [NSKeyedArchiver archivedDataWithRootObject:args];
}

static NSArray *MMUnarchiveArgs(NSData *data)
{
    id obj = nil;
#if MAC_OS_X_VERSION_MAX_ALLOWED >= MAC_OS_X_VERSION_10_13
    if (AVAILABLE_MAC_OS(10, 13)) {
        NSError *err = nil;
        obj = [NSKeyedUnarchiver unarchivedObjectOfClasses:MMAllowedArgClasses()
                                                  fromData:data error:&err];
        if (!obj) ASLogErr(@"unarchive failed: %@", err);
    } else
#endif
    {
        @try { obj = [NSKeyedUnarchiver unarchiveObjectWithData:data]; }
        @catch (NSException *ex) { ASLogErr(@"unarchive failed: %@", ex); }
    }
    return [obj isKindOfClass:[NSArray class]] ? obj : nil;
}

// Build one envelope frame.  Pure function of its arguments so reply blocks
// need not keep the endpoint alive.
static NSData *MMEncodeEnvelope(uint8_t kind, uint32_t op, uint64_t corr,
                                NSArray *args)
{
    NSData *a = MMArchiveArgs(args);
    NSMutableData *m = [NSMutableData dataWithCapacity:13 + [a length]];
    uint32_t beOp = OSSwapHostToBigInt32(op);
    uint64_t beCorr = OSSwapHostToBigInt64(corr);
    [m appendBytes:&kind length:1];
    [m appendBytes:&beOp length:4];
    [m appendBytes:&beCorr length:8];
    [m appendData:a];
    return m;
}


// One outstanding synchronous request awaiting its reply.
// All fields are guarded by gPumpLock.
@interface MMPendingReply : NSObject {
@public
    id   result;   // retained
    BOOL done;
}
@end
@implementation MMPendingReply
- (void)dealloc { [result release]; [super dealloc]; }
@end


// One inbound REQUEST/ONEWAY awaiting service on the main thread.
@interface MMIncomingItem : NSObject {
@public
    MMSocketRemoteEndpoint *endpoint;    // retained
    uint32_t               op;
    NSArray                *args;        // retained
    void                   (^reply)(id); // heap-copied
}
@end
@implementation MMIncomingItem
- (void)dealloc
{
    [endpoint release];
    [args release];
    [reply release];
    [super dealloc];
}
@end


// --- Process-global pump state ---------------------------------------------
//
// The incoming FIFO and its condition are shared by every socket endpoint in
// the process.  This is deliberate: the GUI holds one endpoint per Vim child,
// and a main thread blocked on endpoint A's reply must still be able to serve
// a request arriving on endpoint B (DO's NSConnectionReplyMode serviced all
// connections during a reply wait; a per-endpoint queue would let a
// three-process cycle, e.g. eval -> remote_expr('VIM2') -> serverlist(),
// deadlock).
//
// Inbound REQUEST/ONEWAY frames are appended to gIncoming and served, in FIFO
// order and always on the main thread, from one of two places:
//  - the run-loop source gDrainSource (installed in the common modes, and in
//    any extra mode requested via addRequestRunLoopMode:), or
//  - the pump loop inside sendRequestOpcode:, which serves queued items while
//    it waits for its own reply.  This reproduces the DO reply-mode
//    reentrancy the frontend and backend rely on: without it, two peers that
//    issue synchronous calls at the same time deadlock (GUI evaluateExpression
//    vs. backend serverList).
//
// A run-loop source is used instead of dispatch_async onto the main queue:
// the main GCD queue is not drained by run loops nested inside a main-queue
// callback, nor in non-common modes such as NSEventTrackingRunLoopMode.

static NSCondition       *gPumpLock;
static NSMutableArray    *gIncoming;      // MMIncomingItem FIFO
static CFRunLoopSourceRef gDrainSource;

static void MMDrainIncomingSourcePerform(void *info);

static void MMPumpInit(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPumpLock = [[NSCondition alloc] init];
        gIncoming = [[NSMutableArray alloc] init];
        CFRunLoopSourceContext ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.perform = MMDrainIncomingSourcePerform;
        gDrainSource = CFRunLoopSourceCreate(NULL, 0, &ctx);
        CFRunLoopAddSource(CFRunLoopGetMain(), gDrainSource,
                           kCFRunLoopCommonModes);
    });
}


@implementation MMSocketRemoteEndpoint {
    MMSocketChannel     *_channel;
    NSMutableArray      *_invalidationHandlers;
    NSMutableDictionary *_pending;       // @(corrId) -> MMPendingReply
    uint64_t             _corrCounter;
    NSTimeInterval       _requestTimeout;
    NSTimeInterval       _replyTimeout;
    BOOL                 _invalidated;   // guarded by gPumpLock
}

- (instancetype)initWithChannel:(MMSocketChannel *)channel
{
    if (!(self = [super init])) return nil;
    if (!channel) { [self release]; return nil; }
    MMPumpInit();
    _channel = [channel retain];
    _invalidationHandlers = [[NSMutableArray alloc] init];
    _pending = [[NSMutableDictionary alloc] init];
    _requestTimeout = -1;
    _replyTimeout = -1;

    __block __unsafe_unretained MMSocketRemoteEndpoint *weakSelf = self;
    _channel.frameHandler = ^(NSData *payload) { [weakSelf handleFrame:payload]; };
    _channel.invalidationHandler = ^{ [weakSelf handleChannelInvalidated]; };
    return self;
}

- (void)dealloc
{
    [_channel invalidate];
    [_channel release];
    [_invalidationHandlers release];
    [_pending release];
    [super dealloc];
}

- (MMSocketChannel *)channel { return _channel; }

- (void)activate
{
    // The caller must have set incomingHandler (and any invalidation
    // handlers) by now; frames may arrive as soon as the channel resumes,
    // and the peer's first frame can be a REQUEST (registration).
    [_channel resume];
}

#pragma mark - Frame handling (channel queue)

- (void)handleFrame:(NSData *)payload
{
    if ([payload length] < 13) {
        ASLogErr(@"Short IPC frame (%lu bytes)", (unsigned long)[payload length]);
        return;
    }
    const uint8_t *p = [payload bytes];
    uint8_t kind = p[0];
    uint32_t op; memcpy(&op, p + 1, 4); op = OSSwapBigToHostInt32(op);
    uint64_t corr; memcpy(&corr, p + 5, 8); corr = OSSwapBigToHostInt64(corr);

    NSData *argsData = [payload subdataWithRange:NSMakeRange(13, [payload length] - 13)];
    NSArray *args = MMUnarchiveArgs(argsData);
    if (!args) args = @[];

    if (kind == MMFrameReply) {
        // Replies are consumed immediately, never queued behind unserved
        // requests, so a blocked caller wakes as soon as its answer arrives.
        [gPumpLock lock];
        MMPendingReply *pr = [_pending objectForKey:@(corr)];
        if (pr) {
            pr->result = [(args.count ? args[0] : [NSNull null]) retain];
            pr->done = YES;
            [gPumpLock broadcast];
        }
        [gPumpLock unlock];
        return;
    }

    // REQUEST or ONEWAY: queue for service on the main thread.
    MMIncomingItem *item = [[MMIncomingItem alloc] init];
    item->endpoint = [self retain];
    item->op = op;
    item->args = [args retain];
    if (kind == MMFrameRequest) {
        // The reply block captures the channel (retained by the block copy),
        // not the endpoint: items can outlive the endpoint's owner, and the
        // channel no-ops sends after invalidation.
        MMSocketChannel *chan = _channel;
        item->reply = [^(id result) {
            [chan sendFrame:MMEncodeEnvelope(MMFrameReply, op, corr,
                                             @[ MMBox(result) ])];
        } copy];
    } else {
        item->reply = [^(id result) { (void)result; } copy];
    }

    [gPumpLock lock];
    if (_invalidated) {
        [gPumpLock unlock];
        [item release];
        return;
    }
    [gIncoming addObject:item];
    [gPumpLock broadcast];   // wake a pumping sendRequestOpcode:
    [gPumpLock unlock];
    [item release];          // gIncoming holds it now

    CFRunLoopSourceSignal(gDrainSource);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

- (void)handleChannelInvalidated
{
    NSMutableArray *dropped = [NSMutableArray array];

    [gPumpLock lock];
    if (_invalidated) {
        [gPumpLock unlock];
        return;
    }
    _invalidated = YES;
    // Purge our queued-but-unserved items *before* firing the invalidation
    // handlers below: the GUI's handler schedules the release of the object
    // that our queued serve targets point at.  Collect the items and release
    // them outside the lock — dropping the last reference to an endpoint
    // while holding gPumpLock could recurse into channel teardown.
    for (NSUInteger i = [gIncoming count]; i > 0; --i) {
        MMIncomingItem *it = [gIncoming objectAtIndex:i-1];
        if (it->endpoint == self) {
            [dropped addObject:it];
            [gIncoming removeObjectAtIndex:i-1];
        }
    }
    // Wake blocked synchronous callers; they observe _invalidated and return
    // nil instead of hanging forever.
    [gPumpLock broadcast];
    [gPumpLock unlock];
    [dropped removeAllObjects];

    NSArray *handlers;
    @synchronized (_invalidationHandlers) {
        handlers = [[_invalidationHandlers copy] autorelease];
        [_invalidationHandlers removeAllObjects];
    }
    for (void (^h)(void) in handlers)
        h();
}

#pragma mark - Serving (main thread)

// Pop the head of the shared FIFO.  Returns a +1 reference, or nil when
// empty.  gPumpLock must be held.
+ (MMIncomingItem *)popIncomingLocked
{
    if ([gIncoming count] == 0) return nil;
    MMIncomingItem *item = [[gIncoming objectAtIndex:0] retain];
    [gIncoming removeObjectAtIndex:0];
    return item;
}

// Serve one inbound frame.  Main thread only; gPumpLock must NOT be held.
+ (void)serveItem:(MMIncomingItem *)item
{
    void (^handler)(uint32_t, NSArray *, void (^)(id)) =
            item->endpoint.incomingHandler;
    if (!handler) {
        // Should not happen post-activate; reply nil so a REQUEST peer is
        // not stranded.
        item->reply(nil);
        return;
    }
    // A handler exception must not unwind through the pump loop and strand
    // the waiter above it.
    @try {
        handler(item->op, item->args, item->reply);
    }
    @catch (NSException *ex) {
        ASLogErr(@"Exception serving IPC op=%u: %@", item->op, ex);
    }
}

static void MMDrainIncomingSourcePerform(void *info)
{
    (void)info;
    for (;;) {
        [gPumpLock lock];
        MMIncomingItem *item = [MMSocketRemoteEndpoint popIncomingLocked];
        [gPumpLock unlock];
        if (!item) break;
        [MMSocketRemoteEndpoint serveItem:item];
        [item release];
    }
}

#pragma mark - Sending

- (void)sendOnewayOpcode:(uint32_t)opcode args:(NSArray *)args
{
    if (_invalidated) return;
    [_channel sendFrame:MMEncodeEnvelope(MMFrameOneway, opcode, 0, args)];
}

- (id)sendRequestOpcode:(uint32_t)opcode args:(NSArray *)args
{
    // Replies are delivered on the channel queue; waiting for one there can
    // never succeed.
    NSAssert(![_channel isOnPrivateQueue],
             @"synchronous IPC request on the channel queue");

    MMPendingReply *pr = [[MMPendingReply alloc] init];
    uint64_t corr;

    [gPumpLock lock];
    if (_invalidated) {
        [gPumpLock unlock];
        [pr release];
        return nil;
    }
    corr = ++_corrCounter;
    [_pending setObject:pr forKey:@(corr)];
    [gPumpLock unlock];

    [_channel sendFrame:MMEncodeEnvelope(MMFrameRequest, opcode, corr, args)];

    NSDate *deadline = (_replyTimeout <= 0)
        ? [NSDate distantFuture]
        : [NSDate dateWithTimeIntervalSinceNow:_replyTimeout];
    // Only the main thread may serve handlers (they touch AppKit / Vim core
    // state); other callers just wait and rely on the run-loop source.
    BOOL pump = [NSThread isMainThread];
    BOOL timedOut = NO;

    [gPumpLock lock];
    for (;;) {
        if (pr->done || _invalidated)
            break;
        if (pump) {
            MMIncomingItem *item = [MMSocketRemoteEndpoint popIncomingLocked];
            if (item) {
                [gPumpLock unlock];
                [MMSocketRemoteEndpoint serveItem:item];
                [item release];
                [gPumpLock lock];
                continue;   // re-check the reply before waiting
            }
        }
        if ([deadline timeIntervalSinceNow] <= 0) {
            timedOut = YES;
            break;
        }
        // Bounded slices are defensive only; every state change (reply,
        // enqueue, invalidation) broadcasts under this lock.
        NSDate *slice = [NSDate dateWithTimeIntervalSinceNow:0.25];
        [gPumpLock waitUntilDate:[deadline earlierDate:slice]];
    }
    id result = pr->done ? [[pr->result retain] autorelease] : nil;
    [_pending removeObjectForKey:@(corr)];
    [gPumpLock unlock];
    [pr release];

    if (timedOut)
        ASLogErr(@"IPC request op=%u timed out", opcode);
    return MMUnbox(result);
}

#pragma mark - Proxies

- (id<MMBackendEndpoint>)backendProxy
{
    return [[[MMSocketBackendProxy alloc] initWithEndpoint:self] autorelease];
}

- (id<MMAppEndpoint>)appProxy
{
    return [[[MMSocketAppProxy alloc] initWithEndpoint:self] autorelease];
}

#pragma mark - MMRemoteEndpoint

- (BOOL)isValid
{
    // Unsynchronized read; validity is inherently racy against a peer that
    // is dying concurrently, and callers already treat it as advisory.
    return !_invalidated && [_channel isValid];
}

// NOTE on timeouts: on NSConnection, requestTimeout bounds *sending* a
// request and replyTimeout bounds waiting for the answer.  Socket sends are
// asynchronous and cannot block, so requestTimeout is stored only for
// protocol compatibility; replyTimeout (<= 0 means forever, matching the DO
// defaults) bounds the reply wait in sendRequestOpcode:.
- (NSTimeInterval)requestTimeout { return _requestTimeout; }
- (void)setRequestTimeout:(NSTimeInterval)seconds { _requestTimeout = seconds; }
- (void)setReplyTimeout:(NSTimeInterval)seconds { _replyTimeout = seconds; }

- (id)addInvalidationHandler:(void (^)(void))handler
{
    if (!handler) return nil;
    void (^copied)(void) = [handler copy];
    @synchronized (_invalidationHandlers) { [_invalidationHandlers addObject:copied]; }
    [copied release];
    return copied;
}

- (void)removeInvalidationHandler:(id)token
{
    if (!token) return;
    @synchronized (_invalidationHandlers) { [_invalidationHandlers removeObjectIdenticalTo:token]; }
}

// The drain source lives in the common modes; these add/remove it in extra
// modes (e.g. NSEventTrackingRunLoopMode during live resize) so inbound
// frames keep flowing there, mirroring NSConnection's addRequestMode:.  The
// source is process-global, so the mode set is shared by all endpoints; in
// practice only one window is in live resize at a time.
- (void)addRequestRunLoopMode:(NSString *)mode
{
    if (mode)
        CFRunLoopAddSource(CFRunLoopGetMain(), gDrainSource, (CFStringRef)mode);
}

- (void)removeRequestRunLoopMode:(NSString *)mode
{
    if (mode && ![mode isEqualToString:(NSString *)kCFRunLoopCommonModes])
        CFRunLoopRemoveSource(CFRunLoopGetMain(), gDrainSource,
                              (CFStringRef)mode);
}

@end


// ===========================================================================
// MMSocketBackendProxy — GUI-side proxy that calls the Vim backend.
// ===========================================================================

@implementation MMSocketBackendProxy {
    MMSocketRemoteEndpoint *_ep;
}

- (instancetype)initWithEndpoint:(MMSocketRemoteEndpoint *)ep
{
    if (!(self = [super init])) return nil;
    _ep = [ep retain];
    return self;
}
- (void)dealloc { [_ep release]; [super dealloc]; }

#pragma mark MMBackendEndpoint (oneway)
- (void)processInput:(int)msgid data:(NSData *)data
{ [_ep sendOnewayOpcode:MMOpProcessInputData args:@[ @(msgid), MMBox(data) ]]; }

- (void)setDialogReturn:(id)obj
{ [_ep sendOnewayOpcode:MMOpSetDialogReturn args:@[ MMBox(obj) ]]; }

- (void)insertOrReplaceSelectedText:(NSString *)text
{ [_ep sendOnewayOpcode:MMOpInsertOrReplaceSelectedText args:@[ MMBox(text) ]]; }

- (void)acknowledgeConnection
{ [_ep sendOnewayOpcode:MMOpAcknowledgeConnection args:@[]]; }

#pragma mark MMBackendEndpoint (synchronous)
- (NSString *)evaluateExpression:(NSString *)expr
{ return [_ep sendRequestOpcode:MMOpEvaluateExpression args:@[ MMBox(expr) ]]; }

- (MMEvalResult *)evaluateExpressionCocoa:(NSString *)expr
{ return [_ep sendRequestOpcode:MMOpEvaluateExpressionCocoa args:@[ MMBox(expr) ]]; }

- (BOOL)hasSelectedText
{ return [[_ep sendRequestOpcode:MMOpHasSelectedText args:@[]] boolValue]; }

- (NSString *)selectedText
{ return [_ep sendRequestOpcode:MMOpSelectedText args:@[]]; }

- (MMSelectionInfo *)mouseScreenposIsSelection:(int)row column:(int)column
{ return [_ep sendRequestOpcode:MMOpMouseScreenposIsSelection args:@[ @(row), @(column) ]]; }

#pragma mark Serve (backend side: decode -> MMBackend)
+ (void)serveOpcode:(uint32_t)op args:(NSArray *)args
             target:(id<MMBackendEndpoint>)t reply:(void (^)(id))reply
{
    switch (op) {
    case MMOpProcessInputData:
        [t processInput:[args[0] intValue] data:MMUnbox(args[1])];
        break;
    case MMOpSetDialogReturn:
        [t setDialogReturn:MMUnbox(args[0])];
        break;
    case MMOpInsertOrReplaceSelectedText:
        [t insertOrReplaceSelectedText:MMUnbox(args[0])];
        break;
    case MMOpAcknowledgeConnection:
        [t acknowledgeConnection];
        break;
    case MMOpEvaluateExpression:
        reply([t evaluateExpression:MMUnbox(args[0])]);
        break;
    case MMOpEvaluateExpressionCocoa:
        reply([t evaluateExpressionCocoa:MMUnbox(args[0])]);
        break;
    case MMOpHasSelectedText:
        reply(@([t hasSelectedText]));
        break;
    case MMOpSelectedText:
        reply([t selectedText]);
        break;
    case MMOpMouseScreenposIsSelection:
        reply([t mouseScreenposIsSelection:[args[0] intValue] column:[args[1] intValue]]);
        break;
    default:
        ASLogErr(@"Unknown backend opcode %u", op);
        reply(nil);
        break;
    }
}

@end


// ===========================================================================
// MMSocketAppProxy — backend-side proxy that calls the GUI.
// ===========================================================================

@implementation MMSocketAppProxy {
    MMSocketRemoteEndpoint *_ep;
}

- (instancetype)initWithEndpoint:(MMSocketRemoteEndpoint *)ep
{
    if (!(self = [super init])) return nil;
    _ep = [ep retain];
    return self;
}
- (void)dealloc { [_ep release]; [super dealloc]; }

#pragma mark MMAppEndpoint
- (unsigned long)connectBackend:(id<MMBackendEndpoint>)backend pid:(int)pid
{
    // Unused on the socket transport; registration is the handshake below.
    (void)backend;
    return [self registerBackendWithPid:pid];
}

- (unsigned long)registerBackendWithPid:(int)pid
{
    id r = [_ep sendRequestOpcode:MMOpRegisterBackend args:@[ @(pid) ]];
    return [r unsignedLongValue];
}

- (void)processInput:(NSArray *)queue forIdentifier:(unsigned long)identifier
{
    [_ep sendOnewayOpcode:MMOpProcessInputForIdentifier
                     args:@[ MMBox(queue), @(identifier) ]];
}

- (NSArray *)serverList
{
    return [_ep sendRequestOpcode:MMOpServerList args:@[]];
}

#pragma mark Serve (GUI side: decode -> MMAppController)
// The GUI target must respond to MMAppEndpoint plus -registerBackendWithPid:.
+ (void)serveOpcode:(uint32_t)op args:(NSArray *)args
             target:(id)t reply:(void (^)(id))reply
{
    switch (op) {
    case MMOpRegisterBackend:
        reply(@([t registerBackendWithPid:[args[0] intValue]]));
        break;
    case MMOpProcessInputForIdentifier:
        [t processInput:MMUnbox(args[0]) forIdentifier:[args[1] unsignedLongValue]];
        break;
    case MMOpServerList:
        reply([t serverList]);
        break;
    default:
        ASLogErr(@"Unknown app opcode %u", op);
        reply(nil);
        break;
    }
}

@end
