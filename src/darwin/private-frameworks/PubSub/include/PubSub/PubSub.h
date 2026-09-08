// SPDX-License-Identifier: MIT-0

#ifndef _PUBSUB_H_
#define _PUBSUB_H_

#import <Foundation/Foundation.h>

/*
 * WHAT IS HERE AND WHAT IS NOT.
 *
 * PubSub is the RSS and Atom framework Apple shipped from 10.5 and removed in 10.15. It moved from
 * Frameworks to PrivateFrameworks along the way, with a symlink left behind, which is why the
 * testsuite dlopens the private path.
 *
 * ONE STRING CONSTANT HAS A KNOWN VALUE and it is the one the testsuite pins:
 * PSFeedRefreshingNotification is @"PSFeedRefreshing". The other seven that the framework exports
 * are NOT declared here, because a notification name with the wrong value is silent: the poster and
 * the observer simply never meet, and nothing reports it. An undefined symbol is loud. They are
 * named here so the next person does not have to find the list again:
 *
 *   PSEnclosureDownloadStateDidChangeNotification  PSErrorDomain
 *   PSFeedAddedEntriesKey                          PSFeedDidChangeEntryFlagsKey
 *   PSFeedEntriesChangedNotification               PSFeedRemovedEntriesKey
 *   PSFeedUpdatedEntriesKey
 *
 * The enumerations below ARE exact: they come from the PyObjC bindings in vendor/src, which are
 * generated from Apple's own headers.
 *
 * THE CLASSES ARE ABSENT ON PURPOSE. PSClient, PSFeed, PSEntry, PSEnclosure, PSFeedSettings and
 * PSLink are real classes with behaviour, and an empty class that answers nil to everything is a
 * policy answer pretending to be an implementation. NSClassFromString returning nil is something a
 * caller can test for.
 */

enum {
    PSUnknownFormat = 0,
    PSRSSFormat = 1,
    PSAtomFormat = 2,
};

enum {
    PSLinkToOther = 0,
    PSLinkToRSS = 1,
    PSLinkToAtom = 2,
    PSLinkToAtomService = 3,
    PSLinkToFOAF = 4,
    PSLinkToRSD = 5,
    PSLinkToSelf = 6,
    PSLinkToAlternate = 7,
};

enum {
    PSEnclosureDownloadIsIdle = 0,
    PSEnclosureDownloadIsQueued = 1,
    PSEnclosureDownloadIsActive = 2,
    PSEnclosureDownloadDidFinish = 3,
    PSEnclosureDownloadDidFail = 4,
    PSEnclosureDownloadWasDeleted = 5,
};

enum {
    PSInternalError = 1,
    PSNotAFeedError = 2,
};

enum {
    PSFeedSettingsUnlimitedSize = 0,
};

extern NSString *const PSFeedRefreshingNotification;

#endif // _PUBSUB_H_
