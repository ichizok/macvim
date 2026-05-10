/* vi:set ts=8 sts=4 sw=4 ft=objc:
 *
 * VIM - Vi IMproved		by Bram Moolenaar
 *				MacVim GUI port by Bjorn Winckler
 *
 * Do ":help uganda"  in Vim to read copying and usage conditions.
 * Do ":help credits" in Vim to see a list of people who contributed.
 * See README.txt for an overview of the Vim source code.
 */

#import "MMEvalResult.h"

static NSString * const kValueKey = @"value";
static NSString * const kErrorKey = @"errorString";

@implementation MMEvalResult

+ (BOOL)supportsSecureCoding { return YES; }

+ (instancetype)resultWithValue:(id)value errorString:(NSString *)errorString
{
    return [[[self alloc] initWithValue:value errorString:errorString] autorelease];
}

+ (instancetype)resultWithValue:(id)value
{
    return [self resultWithValue:value errorString:nil];
}

+ (instancetype)resultWithErrorString:(NSString *)errorString
{
    return [self resultWithValue:nil errorString:errorString];
}

- (instancetype)initWithValue:(id)value errorString:(NSString *)errorString
{
    if (!(self = [super init])) return nil;
    _value = [value copy];
    _errorString = [errorString copy];
    return self;
}

- (void)dealloc
{
    [_value release];
    [_errorString release];
    [super dealloc];
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    if (!(self = [super init])) return nil;
    // The value can be any Vim-derived object (NSString, NSNumber, NSArray,
    // NSDictionary, NSData, NSNull) so we whitelist exactly that set.
    NSSet *allowed = [NSSet setWithObjects:
                      [NSString class], [NSNumber class], [NSArray class],
                      [NSDictionary class], [NSData class], [NSNull class],
                      nil];
    _value = [[coder decodeObjectOfClasses:allowed forKey:kValueKey] copy];
    _errorString = [[coder decodeObjectOfClass:[NSString class]
                                        forKey:kErrorKey] copy];
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
    [coder encodeObject:_value forKey:kValueKey];
    [coder encodeObject:_errorString forKey:kErrorKey];
}

@end
