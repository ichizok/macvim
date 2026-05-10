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

/// Result of a hit-test against the current visual selection.
///
/// Replaces a pair of byref out parameters from MMBackendProtocol so the call
/// can survive a transport that does not support output arguments (NSXPC).
@interface MMSelectionInfo : NSObject <NSSecureCoding>

@property (nonatomic, readonly) BOOL isSelection;
@property (nonatomic, readonly) int startRow;
@property (nonatomic, readonly) int startColumn;

+ (instancetype)infoWithIsSelection:(BOOL)isSelection
                           startRow:(int)startRow
                        startColumn:(int)startColumn;

+ (instancetype)notSelected;

@end
