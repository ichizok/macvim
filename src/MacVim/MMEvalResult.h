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

NS_ASSUME_NONNULL_BEGIN

/// Result of evaluating a Vim expression that can also report a textual error.
///
/// Replaces an `out bycopy NSString **` parameter on MMBackendProtocol so the
/// call can survive a transport that does not support output arguments (NSXPC).
/// Either `value` or `errorString` is set; both being nil means evaluation
/// returned nil with no error reported.
@interface MMEvalResult : NSObject <NSSecureCoding>

@property (nonatomic, readonly, copy, nullable) id value;
@property (nonatomic, readonly, copy, nullable) NSString *errorString;

+ (instancetype)resultWithValue:(nullable id)value
                    errorString:(nullable NSString *)errorString;

+ (instancetype)resultWithValue:(nullable id)value;
+ (instancetype)resultWithErrorString:(NSString *)errorString;

@end

NS_ASSUME_NONNULL_END
