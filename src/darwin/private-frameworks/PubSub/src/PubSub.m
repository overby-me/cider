// SPDX-License-Identifier: MIT-0

#import <PubSub/PubSub.h>

/*
 * THE VALUE IS PINNED BY THE TESTSUITE, not chosen here:
 * System/Library/PrivateFrameworks/PubSub.framework/test/test_PubSub_variable.m asserts
 * PSFeedRefreshingNotification equals @"PSFeedRefreshing" on macOS 14.7 and earlier.
 */
NSString *const PSFeedRefreshingNotification = @"PSFeedRefreshing";
