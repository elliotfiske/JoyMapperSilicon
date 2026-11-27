#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, if any. Some AVFoundation calls
/// (AVAudioNode's installTap) report bad state by raising, which Swift can't catch and which
/// otherwise aborts the app.
NSException * _Nullable JMCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
