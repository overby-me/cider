/*
 This file is part of Cider.

 Cider is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Cider is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Cider.  If not, see <http://www.gnu.org/licenses/>.
*/

/*
 * The AddressBook C API, which this framework did not have at all: the Darling AddressBook is a
 * set of reverse engineered ObjC class stubs, and the C entry points a document application
 * actually calls were simply absent.
 *
 * THE FOUR CONSTANTS ARE WHY THIS FILE EXISTS. LibreOffice binds them EAGERLY through
 * libmergedlo.dylib, so their absence is not a missing feature but a process that will not
 * start: a two level namespace binary resolves data symbols at load and dyld aborts on the
 * first one it cannot find. Measured with scratchpad/lo-gap.py and written up in
 * docs/libreoffice-gap.md.
 *
 * AN EMPTY ADDRESS BOOK IS A LEGITIMATE IMPLEMENTATION of every function here, and it is the
 * honest one: there is no address book on this platform, so reporting one with no entries is
 * true. It is also what a Mac with an empty Contacts database looks like, which is a state
 * every caller of this API must already handle.
 *
 * The values of the constants are the documented ones rather than invented, because a caller is
 * entitled to compare them against keys it read from a file it wrote on a real Mac.
 */

#include <CoreFoundation/CoreFoundation.h>

/* Opaque in the real framework too; declared here because there is no header to include. */
typedef CFTypeRef ABAddressBookRef;
typedef CFTypeRef ABRecordRef;
typedef CFTypeRef ABMultiValueRef;

const CFStringRef kABGroupNameProperty = CFSTR("GroupName");
const CFStringRef kABModificationDateProperty = CFSTR("Modification");
const CFStringRef kABPersonRecordType = CFSTR("ABPerson");
const CFStringRef kABUIDProperty = CFSTR("UID");

/*
 * NULL, NOT AN EMPTY ADDRESS BOOK OBJECT. Returning a shared instance would mean every other
 * call has to keep pretending, and a caller that checks for NULL here takes its own no-contacts
 * path, which is better tested code than ours.
 */
ABAddressBookRef ABGetSharedAddressBook(void)
{
	return NULL;
}

/*
 * EMPTY ARRAYS RATHER THAN NULL for the copy-array calls: the names begin with Copy, so the
 * caller owns and releases the result, and a NULL there is the difference between a loop that
 * runs zero times and one that crashes on release.
 */
CFArrayRef ABCopyArrayOfAllPeople(ABAddressBookRef addressBook)
{
	(void) addressBook;
	return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef ABCopyArrayOfAllGroups(ABAddressBookRef addressBook)
{
	(void) addressBook;
	return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef ABGroupCopyArrayOfAllMembers(ABRecordRef group)
{
	(void) group;
	return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

CFArrayRef ABCopyArrayOfPropertiesForRecordType(ABAddressBookRef addressBook, CFStringRef recordType)
{
	(void) addressBook;
	(void) recordType;
	return CFArrayCreate(NULL, NULL, 0, &kCFTypeArrayCallBacks);
}

/*
 * NULL for the per-record reads. There are no records, so there is nothing any of these could
 * be asked about; a caller reaches them only after one of the arrays above handed it something.
 */
CFStringRef ABCopyLocalizedPropertyOrLabel(CFStringRef propertyOrLabel)
{
	(void) propertyOrLabel;
	return NULL;
}

CFTypeRef ABRecordCopyValue(ABRecordRef record, CFStringRef property)
{
	(void) record;
	(void) property;
	return NULL;
}

CFStringRef ABMultiValueCopyLabelAtIndex(ABMultiValueRef multiValue, CFIndex index)
{
	(void) multiValue;
	(void) index;
	return NULL;
}

CFTypeRef ABMultiValueCopyValueAtIndex(ABMultiValueRef multiValue, CFIndex index)
{
	(void) multiValue;
	(void) index;
	return NULL;
}

CFIndex ABMultiValueCount(ABMultiValueRef multiValue)
{
	(void) multiValue;
	return 0;
}

/*
 * kABErrorInProperty is 0 in the real header, and it is the right answer for a property nobody
 * has: the type of a value that does not exist is not a string or a date, it is an error.
 */
CFIndex ABMultiValuePropertyType(ABMultiValueRef multiValue)
{
	(void) multiValue;
	return 0;
}

CFIndex ABTypeOfProperty(ABAddressBookRef addressBook, CFStringRef recordType, CFStringRef property)
{
	(void) addressBook;
	(void) recordType;
	(void) property;
	return 0;
}
