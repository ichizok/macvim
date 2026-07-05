/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMSocketChannel.h"
#import "MacVim.h"          // ASLog*

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>

// Reject absurd frame sizes (corruption / desync) rather than allocating wild
// amounts of memory.  256 MB is far above any legitimate MacVim IPC payload.
static const uint32_t MMSocketMaxFrameLength = 256u * 1024u * 1024u;

// Queue-specific key used to detect when code runs on a channel's private
// queue (the stored value distinguishes between channels).
static void *MMSocketChannelQueueKey = &MMSocketChannelQueueKey;

NSString *MMFrontendSocketPath(void)
{
    // Per-user temp dir, identical across processes regardless of $TMPDIR.
    char buf[PATH_MAX];
    size_t n = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, sizeof(buf));
    NSString *dir = (n > 0 && n <= sizeof(buf))
        ? [NSString stringWithUTF8String:buf]
        : NSTemporaryDirectory();

    // Deterministic FNV-1a hash of the bundle path so different MacVim installs
    // get distinct sockets and the filename stays short (sockaddr_un is ~104).
    const char *bp = [[[NSBundle mainBundle] bundlePath] fileSystemRepresentation];
    uint64_t h = 1469598103934665603ULL;
    for (const char *c = bp; c && *c; ++c) {
        h ^= (uint8_t)*c;
        h *= 1099511628211ULL;
    }
    return [dir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"org.vim.MacVim.%016llx.sock", h]];
}

@implementation MMSocketChannel {
    int                _fd;
    dispatch_queue_t   _queue;        // serial: delivery + framing
    dispatch_io_t      _io;
    dispatch_group_t   _writeGroup;   // tracks writes not yet on the wire
    NSMutableData     *_readBuffer;
    BOOL               _invalidated;
    BOOL               _resumed;
}

- (instancetype)initWithFileDescriptor:(int)fd
{
    if (!(self = [super init])) return nil;
    if (fd < 0) {
        [self release];
        return nil;
    }
    _fd = fd;
    _readBuffer = [[NSMutableData alloc] init];
    _queue = dispatch_queue_create("org.vim.MacVim.socketchannel", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, MMSocketChannelQueueKey, _queue, NULL);
    _writeGroup = dispatch_group_create();

    __block int capturedFd = _fd;
    _io = dispatch_io_create(DISPATCH_IO_STREAM, _fd, _queue, ^(int error) {
        (void)error;
        close(capturedFd);
    });
    if (!_io) {
        close(_fd);
        _fd = -1;
        [self release];
        return nil;
    }
    // Deliver inbound bytes as soon as they arrive.
    dispatch_io_set_low_water(_io, 1);
    return self;
}

+ (instancetype)channelByConnectingToPath:(NSString *)path
{
    const char *cpath = [path fileSystemRepresentation];
    struct sockaddr_un addr;
    if (!cpath || strlen(cpath) >= sizeof(addr.sun_path)) {
        ASLogErr(@"Socket path too long: %@", path);
        return nil;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        ASLogErr(@"socket() failed: %s", strerror(errno));
        return nil;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, cpath, sizeof(addr.sun_path));

    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) != 0) {
        // Common and expected when the GUI is not (yet) listening.
        ASLogDebug(@"connect(%@) failed: %s", path, strerror(errno));
        close(fd);
        return nil;
    }

    return [[[self alloc] initWithFileDescriptor:fd] autorelease];
}

- (void)dealloc
{
    [self invalidate];
    if (_io) dispatch_release(_io);
    if (_queue) dispatch_release(_queue);
    if (_writeGroup) dispatch_release(_writeGroup);
    [_readBuffer release];
    [super dealloc];
}

- (BOOL)isValid
{
    return !_invalidated;
}

- (void)resume
{
    if (_resumed || _invalidated) return;
    _resumed = YES;

    // NOTE: Capture self strongly (block copy retains under MRC).  The final
    // read callback (done=true, on close/EOF) can be scheduled after the owner
    // released us; an unretained self would then dereference a freed
    // _readBuffer.  The retain lasts only until that final callback runs and
    // the block is destroyed; owners break it by calling -invalidate.
    dispatch_io_read(_io, 0, SIZE_MAX, _queue,
        ^(bool done, dispatch_data_t data, int error) {
            if (data && dispatch_data_get_size(data) > 0) {
                dispatch_data_apply(data,
                    ^bool(dispatch_data_t region, size_t offset,
                          const void *buffer, size_t size) {
                        (void)region; (void)offset;
                        [self->_readBuffer appendBytes:buffer length:size];
                        return true;
                    });
                [self drainReadBuffer];
            }
            if (error || done) {
                // EOF (done with no error) or hard error: peer is gone.
                [self handleDisconnect];
            }
        });
}

// Runs on _queue.  Extract every complete [len][payload] frame.
- (void)drainReadBuffer
{
    for (;;) {
        NSUInteger avail = [_readBuffer length];
        if (avail < sizeof(uint32_t))
            break;

        uint32_t beLen = 0;
        [_readBuffer getBytes:&beLen length:sizeof(beLen)];
        uint32_t len = ntohl(beLen);

        if (len > MMSocketMaxFrameLength) {
            ASLogErr(@"Bogus frame length %u; dropping connection", len);
            [self handleDisconnect];
            return;
        }
        if (avail < sizeof(uint32_t) + (NSUInteger)len)
            break;  // wait for the rest

        NSData *payload = [_readBuffer subdataWithRange:
                NSMakeRange(sizeof(uint32_t), len)];
        // Consume the frame from the head of the buffer.
        [_readBuffer replaceBytesInRange:
                NSMakeRange(0, sizeof(uint32_t) + (NSUInteger)len)
                              withBytes:NULL length:0];

        if (self.frameHandler)
            self.frameHandler(payload);
        if (_invalidated)
            return;  // a handler may have torn us down
    }
}

- (void)sendFrame:(NSData *)payload
{
    if (_invalidated || !_io) return;

    NSUInteger plen = [payload length];
    uint32_t beLen = htonl((uint32_t)plen);

    NSMutableData *frame = [[NSMutableData alloc] initWithCapacity:sizeof(beLen) + plen];
    [frame appendBytes:&beLen length:sizeof(beLen)];
    if (plen) [frame appendData:payload];

    // dispatch_data copies the bytes (DEFAULT destructor), so the NSMutableData
    // can be released immediately.
    dispatch_data_t ddata = dispatch_data_create([frame bytes], [frame length],
            _queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    [frame release];

    dispatch_group_enter(_writeGroup);
    dispatch_group_t writeGroup = _writeGroup;
    dispatch_io_write(_io, 0, ddata, _queue,
        ^(bool done, dispatch_data_t remaining, int error) {
            (void)remaining;
            if (error)
                ASLogDebug(@"socket write error: %s", strerror(error));
            // The handler fires multiple times with partial progress; the
            // final invocation (done, whether success or error) balances the
            // enter above.
            if (done)
                dispatch_group_leave(writeGroup);
        });
    dispatch_release(ddata);
}

- (BOOL)flushWithTimeout:(NSTimeInterval)timeout
{
    dispatch_time_t deadline = (timeout < 0)
        ? DISPATCH_TIME_FOREVER
        : dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    return dispatch_group_wait(_writeGroup, deadline) == 0;
}

// Runs on _queue.  Single-shot transition to invalid + fire handler.
- (void)handleDisconnect
{
    if (_invalidated) return;
    _invalidated = YES;
    if (_io) dispatch_io_close(_io, DISPATCH_IO_STOP);
    void (^h)(void) = self.invalidationHandler;
    if (h) h();
}

- (BOOL)isOnPrivateQueue
{
    return dispatch_get_specific(MMSocketChannelQueueKey) == (void *)_queue;
}

- (void)invalidate
{
    if (_invalidated) return;
    if ([self isOnPrivateQueue]) {
        // Already serialized with the read/frame handlers; a dispatch_sync
        // onto our own queue would deadlock (e.g. when the last reference to
        // our owner is dropped from a block running on this queue).
        _invalidated = YES;
        if (_io) dispatch_io_close(_io, DISPATCH_IO_STOP);
        return;
    }
    // Serialize teardown with the read/frame handlers.
    dispatch_sync(_queue, ^{
        if (_invalidated) return;
        _invalidated = YES;
        if (_io) dispatch_io_close(_io, DISPATCH_IO_STOP);
    });
}

@end


// ---------------------------------------------------------------------------

@implementation MMSocketListener {
    int               _fd;
    dispatch_queue_t  _queue;
    dispatch_source_t _source;
    BOOL              _invalidated;
}

@synthesize path = _path;

+ (instancetype)listenerWithPath:(NSString *)path
{
    const char *cpath = [path fileSystemRepresentation];
    struct sockaddr_un addr;
    if (!cpath || strlen(cpath) >= sizeof(addr.sun_path)) {
        ASLogErr(@"Listener path too long: %@", path);
        return nil;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        ASLogErr(@"socket() failed: %s", strerror(errno));
        return nil;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, cpath, sizeof(addr.sun_path));

    // Remove a stale socket file from a previous (crashed) run.
    unlink(cpath);

    if (bind(fd, (struct sockaddr *)&addr, (socklen_t)SUN_LEN(&addr)) != 0) {
        ASLogErr(@"bind(%@) failed: %s", path, strerror(errno));
        close(fd);
        return nil;
    }
    if (listen(fd, 16) != 0) {
        ASLogErr(@"listen(%@) failed: %s", path, strerror(errno));
        close(fd);
        unlink(cpath);
        return nil;
    }
    // Non-blocking so the accept() drain loop terminates on EAGAIN.
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);

    MMSocketListener *l = [[[self alloc] init] autorelease];
    l->_fd = fd;
    l->_path = [path copy];
    l->_queue = dispatch_queue_create("org.vim.MacVim.socketlistener",
            DISPATCH_QUEUE_SERIAL);
    return l;
}

- (void)dealloc
{
    [self invalidate];
    [_path release];
    [super dealloc];
}

- (void)resume
{
    if (_source || _invalidated) return;

    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, _queue);
    __block __unsafe_unretained MMSocketListener *weakSelf = self;
    dispatch_source_set_event_handler(_source, ^{
        for (;;) {
            int cfd = accept(weakSelf->_fd, NULL, NULL);
            if (cfd < 0) {
                if (errno == EINTR) continue;
                break;  // EAGAIN/EWOULDBLOCK: drained
            }
            MMSocketChannel *ch =
                [[[MMSocketChannel alloc] initWithFileDescriptor:cfd] autorelease];
            if (ch && weakSelf.acceptHandler)
                weakSelf.acceptHandler(ch);
        }
    });
    int listenFd = _fd;
    dispatch_source_set_cancel_handler(_source, ^{ close(listenFd); });
    dispatch_resume(_source);
}

- (void)invalidate
{
    if (_invalidated) return;
    _invalidated = YES;
    if (_source) {
        dispatch_source_cancel(_source);  // cancel handler closes _fd
        dispatch_release(_source);
        _source = NULL;
    } else if (_fd >= 0) {
        close(_fd);
    }
    if (_path)
        unlink([_path fileSystemRepresentation]);
    if (_queue) {
        dispatch_release(_queue);
        _queue = NULL;
    }
}

@end
