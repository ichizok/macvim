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


// One outstanding synchronous request awaiting its reply.
@interface MMPendingReply : NSObject {
@public
    dispatch_semaphore_t sem;
    id                   result;   // retained
}
@end
@implementation MMPendingReply
- (instancetype)init { if ((self = [super init])) sem = dispatch_semaphore_create(0); return self; }
- (void)dealloc { if (sem) dispatch_release(sem); [result release]; [super dealloc]; }
@end


@implementation MMSocketRemoteEndpoint {
    MMSocketChannel     *_channel;
    NSMutableArray      *_invalidationHandlers;
    NSMutableDictionary *_pending;       // @(corrId) -> MMPendingReply
    uint64_t             _corrCounter;
    NSTimeInterval       _requestTimeout;
    BOOL                 _invalidated;
}

- (instancetype)initWithChannel:(MMSocketChannel *)channel
{
    if (!(self = [super init])) return nil;
    if (!channel) { [self release]; return nil; }
    _channel = [channel retain];
    _invalidationHandlers = [[NSMutableArray alloc] init];
    _pending = [[NSMutableDictionary alloc] init];
    _requestTimeout = -1;

    __block __unsafe_unretained MMSocketRemoteEndpoint *weakSelf = self;
    _channel.frameHandler = ^(NSData *payload) { [weakSelf handleFrame:payload]; };
    _channel.invalidationHandler = ^{ [weakSelf handleChannelInvalidated]; };
    [_channel resume];
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

#pragma mark - Envelope encode/decode

- (NSData *)encodeKind:(uint8_t)kind opcode:(uint32_t)op
            correlation:(uint64_t)corr args:(NSArray *)args
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

// Runs on the channel's private queue.
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
        MMPendingReply *pr = nil;
        @synchronized (_pending) {
            pr = [[[_pending objectForKey:@(corr)] retain] autorelease];
            [_pending removeObjectForKey:@(corr)];
        }
        if (pr) {
            pr->result = [(args.count ? args[0] : [NSNull null]) retain];
            dispatch_semaphore_signal(pr->sem);
        }
        return;
    }

    // REQUEST or ONEWAY: hand to the local target.
    void (^incoming)(uint32_t, NSArray *, void (^)(id)) = self.incomingHandler;
    if (!incoming) return;

    if (kind == MMFrameRequest) {
        __block __unsafe_unretained MMSocketRemoteEndpoint *weakSelf = self;
        void (^reply)(id) = ^(id result) {
            [weakSelf->_channel sendFrame:
                [weakSelf encodeKind:MMFrameReply opcode:op correlation:corr
                                args:@[ MMBox(result) ]]];
        };
        incoming(op, args, reply);
    } else {
        incoming(op, args, ^(id result) { (void)result; });
    }
}

- (void)handleChannelInvalidated
{
    NSArray *handlers;
    NSArray *pendings;
    @synchronized (_invalidationHandlers) {
        if (_invalidated) return;
        _invalidated = YES;
        handlers = [[_invalidationHandlers copy] autorelease];
        [_invalidationHandlers removeAllObjects];
    }
    // Wake any blocked synchronous callers so they return (with nil) instead
    // of hanging forever.
    @synchronized (_pending) {
        pendings = [[_pending allValues] copy];
        [_pending removeAllObjects];
    }
    for (MMPendingReply *pr in pendings)
        dispatch_semaphore_signal(pr->sem);
    [pendings release];

    for (void (^h)(void) in handlers)
        h();
}

#pragma mark - Sending

- (void)sendOnewayOpcode:(uint32_t)opcode args:(NSArray *)args
{
    if (_invalidated) return;
    [_channel sendFrame:[self encodeKind:MMFrameOneway opcode:opcode
                             correlation:0 args:args]];
}

- (id)sendRequestOpcode:(uint32_t)opcode args:(NSArray *)args
{
    if (_invalidated) return nil;

    uint64_t corr;
    @synchronized (self) { corr = ++_corrCounter; }

    MMPendingReply *pr = [[[MMPendingReply alloc] init] autorelease];
    @synchronized (_pending) { [_pending setObject:pr forKey:@(corr)]; }

    [_channel sendFrame:[self encodeKind:MMFrameRequest opcode:opcode
                             correlation:corr args:args]];

    dispatch_time_t deadline = (_requestTimeout < 0)
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_requestTimeout * NSEC_PER_SEC));
    long timedOut = dispatch_semaphore_wait(pr->sem, deadline);

    @synchronized (_pending) { [_pending removeObjectForKey:@(corr)]; }
    if (timedOut != 0) {
        ASLogErr(@"IPC request op=%u timed out", opcode);
        return nil;
    }
    return MMUnbox(pr->result);
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

- (BOOL)isValid { return !_invalidated && [_channel isValid]; }

- (NSTimeInterval)requestTimeout { return _requestTimeout; }
- (void)setRequestTimeout:(NSTimeInterval)seconds { _requestTimeout = seconds; }
- (void)setReplyTimeout:(NSTimeInterval)seconds { (void)seconds; }

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

- (void)addRequestRunLoopMode:(NSString *)mode { (void)mode; }    // no-op for sockets
- (void)removeRequestRunLoopMode:(NSString *)mode { (void)mode; } // no-op for sockets

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
