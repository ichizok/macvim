/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMSelectionInfo.h"

static NSString * const kIsSelectionKey = @"isSelection";
static NSString * const kStartRowKey    = @"startRow";
static NSString * const kStartColumnKey = @"startColumn";

@implementation MMSelectionInfo

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)infoWithIsSelection:(BOOL)isSelection
                           startRow:(int)startRow
                        startColumn:(int)startColumn
{
    return [[[self alloc] initWithIsSelection:isSelection
                                     startRow:startRow
                                  startColumn:startColumn] autorelease];
}

+ (instancetype)notSelected
{
    return [self infoWithIsSelection:NO startRow:0 startColumn:0];
}

- (instancetype)initWithIsSelection:(BOOL)isSelection
                           startRow:(int)startRow
                        startColumn:(int)startColumn
{
    if (!(self = [super init])) return nil;
    _isSelection = isSelection;
    _startRow    = startRow;
    _startColumn = startColumn;
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    _isSelection = [coder decodeBoolForKey:kIsSelectionKey];
    _startRow    = [coder decodeIntForKey:kStartRowKey];
    _startColumn = [coder decodeIntForKey:kStartColumnKey];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeBool:_isSelection forKey:kIsSelectionKey];
    [coder encodeInt:_startRow     forKey:kStartRowKey];
    [coder encodeInt:_startColumn  forKey:kStartColumnKey];
}

@end
