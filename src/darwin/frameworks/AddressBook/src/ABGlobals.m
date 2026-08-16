/*
 This file is part of Darling.

 Copyright (C) 2019 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/

#import <AddressBook/ABGlobals.h>

NSString *const kABDatabaseChangedNotification=@"ABDatabaseChangedNotification";
NSString *const kABDatabaseChangedExternallyNotification=@"ABDatabaseChangedExternallyNotification";

NSString *const kABAddressProperty=@"ABAddressProperty";
NSString *const kABBirthdayProperty=@"ABBirthdayProperty";
NSString *const kABDepartmentProperty=@"ABDepartmentProperty";
NSString *const kABEmailProperty=@"ABEmailProperty";
NSString *const kABFirstNameProperty=@"ABFirstNameProperty";
NSString *const kABInstantMessageProperty=@"ABInstantMessageProperty";
NSString *const kABJobTitleProperty=@"ABJobTitleProperty";
NSString *const kABLastNameProperty=@"ABLastNameProperty";
NSString *const kABMaidenNameProperty=@"ABMaidenNameProperty";
NSString *const kABMiddleNameProperty=@"ABMiddleNameProperty";
NSString *const kABNicknameProperty=@"ABNicknameProperty";
NSString *const kABOrganizationProperty=@"ABOrganizationProperty";
NSString *const kABOtherDatesProperty=@"ABOtherDatesProperty";
NSString *const kABPhoneProperty=@"ABPhoneProperty";
NSString *const kABTitleProperty=@"ABTitleProperty";
NSString *const kABURLsProperty=@"ABURLsProperty";
NSString *const kABSuffixProperty = @"Suffix";

NSString *const kABPersonFlags=@"ABPersonFlags";

NSString *const kABDeletedRecords=@"ABDeletedRecords";
NSString *const kABInsertedRecords=@"ABInsertedRecords";
NSString *const kABUpdatedRecords=@"ABUpdatedRecords";

// This one is not exported by any header but is required by libraries
NSString *const kABRestoreFromBackup=@"ABRestoreFromBackup";

/*
 * THE LABELS AND THE ADDRESS DICTIONARY KEYS, added for Swift Publisher 5, which reads a contact to
 * build a mailing label and cannot start without them.
 *
 * The values are the ones macOS uses, not invented names. A label is written into the address book
 * database as it stands, so a program that stores _$!<Work>!$_ and reads back something else has a
 * contact whose telephone number has lost its label. The bracketed form is what a real database
 * holds; the application layer turns it into the localised word.
 */

NSString *const kABAddressStreetKey = @"Street";
NSString *const kABAddressCityKey = @"City";
NSString *const kABAddressStateKey = @"State";
NSString *const kABAddressZIPKey = @"ZIP";
NSString *const kABAddressCountryKey = @"Country";
NSString *const kABAddressCountryCodeKey = @"CountryCode";

NSString *const kABInstantMessageUsernameKey = @"InstantMessageUsername";

NSString *const kABHomePageProperty = @"ABHomePage";
NSString *const kABNoteProperty = @"ABNote";

NSString *const kABHomeLabel = @"_$!<Home>!$_";
NSString *const kABWorkLabel = @"_$!<Work>!$_";
NSString *const kABOtherLabel = @"_$!<Other>!$_";
NSString *const kABAnniversaryLabel = @"_$!<Anniversary>!$_";

NSString *const kABAddressHomeLabel = @"_$!<Home>!$_";
NSString *const kABAddressWorkLabel = @"_$!<Work>!$_";

NSString *const kABEmailHomeLabel = @"_$!<Home>!$_";
NSString *const kABEmailWorkLabel = @"_$!<Work>!$_";

NSString *const kABPhoneHomeLabel = @"_$!<Home>!$_";
NSString *const kABPhoneWorkLabel = @"_$!<Work>!$_";
NSString *const kABPhoneMobileLabel = @"_$!<Mobile>!$_";
NSString *const kABPhoneMainLabel = @"_$!<Main>!$_";
NSString *const kABPhoneHomeFAXLabel = @"_$!<HomeFAX>!$_";
NSString *const kABPhoneWorkFAXLabel = @"_$!<WorkFAX>!$_";
NSString *const kABPhonePagerLabel = @"_$!<Pager>!$_";
