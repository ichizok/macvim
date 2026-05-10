/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMDORemoteEndpoint.h"

@implementation MMDORemoteEndpoint {
    NSConnection      *_connection;
    NSMutableArray    *_invalidationHandlers; // array of copied blocks
    id                 _diedObserver;
}

- (instancetype)initWithConnection:(NSConnection *)connection
{
    if (!(self = [super init])) return nil;
    if (!connection) {
        [self release];
        return nil;
    }
    _connection = [connection retain];
    _invalidationHandlers = [[NSMutableArray alloc] init];

    // We funnel NSConnectionDidDieNotification through one observer rather
    // than having every subscriber register its own; this keeps the dispatch
    // semantics identical to a single-shot XPC invalidationHandler.
    __block __unsafe_unretained MMDORemoteEndpoint *weakSelf = self;
    _diedObserver = [[[NSNotificationCenter defaultCenter]
            addObserverForName:NSConnectionDidDieNotification
                        object:_connection
                         queue:nil
                    usingBlock:^(NSNotification *note) {
        (void)note;
        [weakSelf fireInvalidationHandlers];
    }] retain];

    return self;
}

+ (instancetype)endpointForProxy:(id)proxy
{
    if (![proxy isKindOfClass:[NSDistantObject class]])
        return nil;
    NSConnection *conn = [(NSDistantObject *)proxy connectionForProxy];
    if (!conn) return nil;
    return [[[self alloc] initWithConnection:conn] autorelease];
}

- (void)dealloc
{
    if (_diedObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_diedObserver];
        [_diedObserver release];
    }
    [_invalidationHandlers release];
    [_connection release];
    [super dealloc];
}

- (NSConnection *)connection { return _connection; }

#pragma mark - MMRemoteEndpoint

- (BOOL)isValid
{
    return _connection != nil && [_connection isValid];
}

- (NSTimeInterval)requestTimeout
{
    return [_connection requestTimeout];
}

- (void)setRequestTimeout:(NSTimeInterval)seconds
{
    [_connection setRequestTimeout:seconds];
}

- (void)setReplyTimeout:(NSTimeInterval)seconds
{
    [_connection setReplyTimeout:seconds];
}

- (id)addInvalidationHandler:(void (^)(void))handler
{
    if (!handler) return nil;
    void (^copied)(void) = [handler copy];
    @synchronized (_invalidationHandlers) {
        [_invalidationHandlers addObject:copied];
    }
    [copied release];
    return copied; // token == the (copied) block itself
}

- (void)removeInvalidationHandler:(id)token
{
    if (!token) return;
    @synchronized (_invalidationHandlers) {
        [_invalidationHandlers removeObjectIdenticalTo:token];
    }
}

- (void)addRequestRunLoopMode:(NSString *)mode
{
    if (mode) [_connection addRequestMode:mode];
}

- (void)removeRequestRunLoopMode:(NSString *)mode
{
    if (mode) [_connection removeRequestMode:mode];
}

#pragma mark - Internal

- (void)fireInvalidationHandlers
{
    NSArray *snapshot;
    @synchronized (_invalidationHandlers) {
        snapshot = [[_invalidationHandlers copy] autorelease];
        [_invalidationHandlers removeAllObjects];
    }
    for (void (^handler)(void) in snapshot) {
        handler();
    }
}

@end
