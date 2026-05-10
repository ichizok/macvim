/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import <Foundation/Foundation.h>
#import "MMRemoteEndpoint.h"


/// NSConnection-backed adapter conforming to MMRemoteEndpoint.
///
/// One adapter wraps one NSConnection and bridges its lifecycle hooks to the
/// transport-neutral MMRemoteEndpoint surface. Frontend and backend share this
/// adapter; the future NSXPC transport will provide a sibling class.
@interface MMDORemoteEndpoint : NSObject <MMRemoteEndpoint>

/// Designated initializer. The receiver does not retain ownership of the
/// connection's lifetime; callers keep their own NSConnection reference.
- (instancetype)initWithConnection:(NSConnection *)connection;

/// Convenience: returns an MMDORemoteEndpoint for the NSConnection that
/// services the supplied DistantObject proxy. Returns nil if the proxy is not
/// actually a NSDistantObject.
+ (instancetype)endpointForProxy:(id)proxy;

/// Underlying NSConnection. Provided as an escape hatch while the codebase
/// migrates; new code should prefer the MMRemoteEndpoint protocol methods.
@property (nonatomic, readonly) NSConnection *connection;

@end
