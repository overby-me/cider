/*
 * CONSTANTS A CURRENT BINARY LINKS AGAINST.
 *
 * Each of these is a string an application passes to AVFoundation to name a codec, a profile level
 * or a metadata key space. They carry no behaviour: what matters is that the STRING is the one macOS
 * uses, because a dictionary key that differs by a character is a setting that silently does
 * nothing. The values here are the documented ones.
 *
 * They exist because the symbols stop a modern application at load: iTerm2 3.6.10 links all six and
 * dyld refuses to start without them.
 */

#import <Foundation/Foundation.h>

NSString *const AVVideoCodecTypeH264 = @"avc1";
NSString *const AVVideoProfileLevelKey = @"ProfileLevel";
NSString *const AVVideoProfileLevelH264BaselineAutoLevel = @"H264_Baseline_AutoLevel";
NSString *const AVVideoProfileLevelH264MainAutoLevel = @"H264_Main_AutoLevel";
NSString *const AVVideoProfileLevelH264HighAutoLevel = @"H264_High_AutoLevel";
NSString *const AVMetadataKeySpaceQuickTimeMetadata = @"mdta";
