/*
This file is part of Darling.

Copyright (C) 2026 Cider contributors

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

//! The CoreFoundation and libc surface PlistBuddy uses, and NOTHING ELSE (#102).
//!
//! 49 CF functions, which is what the measurement found the program calls. This is deliberately
//! not a CoreFoundation crate: CF is a C API, the port needs the functions it calls, and a crate
//! that modelled all of CF would be a far larger thing to get wrong. There is no vendored
//! core-foundation crate in buck-rust and none is wanted here.
//!
//! EVERY OUTPUT GOES THROUGH C printf, puts AND fwrite. That is not laziness, it is the cheapest
//! way to keep byte parity: C prints a double with %f as six decimal places where Rust would
//! print 3.14, and C stdio decides its own buffering. Reimplementing either would be a
//! difference to hunt rather than a gain.

#![allow(non_upper_case_globals, non_camel_case_types, non_snake_case)]

use core::ffi::{c_char, c_double, c_int, c_long, c_void};

pub type CFTypeRef = *const c_void;
pub type CFStringRef = CFTypeRef;
pub type CFDataRef = CFTypeRef;
pub type CFURLRef = CFTypeRef;
pub type CFArrayRef = CFTypeRef;
pub type CFDictionaryRef = CFTypeRef;
pub type CFNumberRef = CFTypeRef;
pub type CFDateRef = CFTypeRef;
pub type CFTimeZoneRef = CFTypeRef;
pub type CFAllocatorRef = CFTypeRef;
pub type CFPropertyListRef = CFTypeRef;
pub type CFTypeID = usize;
pub type CFIndex = isize;
pub type CFAbsoluteTime = f64;
pub type SInt32 = i32;
pub type UInt8 = u8;

/// CFDate.h. THE FIELD TYPES ARE LOAD BEARING: SInt32 then four SInt8 then a double, so `second`
/// lands at offset 8 because of its own alignment and the struct is 16 bytes. Get this wrong and
/// dates come out plausible and incorrect rather than crashing, which is exactly the failure a
/// gate on written plists is for.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct CFGregorianDate {
    pub year: i32,
    pub month: i8,
    pub day: i8,
    pub hour: i8,
    pub minute: i8,
    pub second: f64,
}

/// CFBase.h. CFRangeMake is an inline function in C, so it is a constructor here, not a call.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct CFRange {
    pub location: CFIndex,
    pub length: CFIndex,
}

pub fn CFRangeMake(location: CFIndex, length: CFIndex) -> CFRange {
    CFRange { location, length }
}

// Darwin's struct tm: nine ints, then the two BSD extensions. strptime and strftime both read and
// write it, so the tail matters even though this program only sets tm_zone.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct tm {
    pub tm_sec: c_int,
    pub tm_min: c_int,
    pub tm_hour: c_int,
    pub tm_mday: c_int,
    pub tm_mon: c_int,
    pub tm_year: c_int,
    pub tm_wday: c_int,
    pub tm_yday: c_int,
    pub tm_isdst: c_int,
    pub tm_gmtoff: c_long,
    pub tm_zone: *mut c_char,
}

pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;
pub const kCFURLPOSIXPathStyle: c_int = 0;
pub const kCFPropertyListMutableContainers: c_int = 1;
pub const kCFNumberFloat64Type: c_int = 6;
pub const kCFNumberLongLongType: c_int = 11;
pub const F_OK: c_int = 0;

unsafe extern "C" {
    // Allocator and the callback tables, which are DATA, not functions: only their addresses are
    // ever used, so the types stay opaque rather than being modelled.
    pub static kCFAllocatorDefault: CFAllocatorRef;
    pub static kCFTypeDictionaryKeyCallBacks: c_void;
    pub static kCFTypeDictionaryValueCallBacks: c_void;
    pub static kCFTypeArrayCallBacks: c_void;
    pub static kCFBooleanTrue: CFTypeRef;
    pub static kCFBooleanFalse: CFTypeRef;

    pub fn CFRelease(cf: CFTypeRef);
    pub fn CFShow(obj: CFTypeRef);
    pub fn CFGetTypeID(cf: CFTypeRef) -> CFTypeID;

    pub fn CFStringGetTypeID() -> CFTypeID;
    pub fn CFArrayGetTypeID() -> CFTypeID;
    pub fn CFDictionaryGetTypeID() -> CFTypeID;
    pub fn CFBooleanGetTypeID() -> CFTypeID;
    pub fn CFNumberGetTypeID() -> CFTypeID;
    pub fn CFDateGetTypeID() -> CFTypeID;
    pub fn CFDataGetTypeID() -> CFTypeID;

    pub fn CFStringCreateWithCString(
        alloc: CFAllocatorRef,
        cstr: *const c_char,
        encoding: u32,
    ) -> CFStringRef;
    pub fn CFStringGetCStringPtr(theString: CFStringRef, encoding: u32) -> *const c_char;

    pub fn CFURLCreateWithFileSystemPath(
        allocator: CFAllocatorRef,
        filePath: CFStringRef,
        pathStyle: c_int,
        isDirectory: bool,
    ) -> CFURLRef;
    pub fn CFURLCreateDataAndPropertiesFromResource(
        alloc: CFAllocatorRef,
        url: CFURLRef,
        resourceData: *mut CFDataRef,
        properties: *mut CFDictionaryRef,
        desiredProperties: CFArrayRef,
        errorCode: *mut SInt32,
    ) -> bool;
    pub fn CFURLWriteDataAndPropertiesToResource(
        url: CFURLRef,
        dataToWrite: CFDataRef,
        propertiesToWrite: CFDictionaryRef,
        errorCode: *mut SInt32,
    ) -> bool;

    pub fn CFPropertyListCreateFromXMLData(
        allocator: CFAllocatorRef,
        xmlData: CFDataRef,
        mutabilityOption: c_int,
        errorString: *mut CFStringRef,
    ) -> CFPropertyListRef;
    pub fn CFPropertyListCreateXMLData(
        allocator: CFAllocatorRef,
        propertyList: CFPropertyListRef,
    ) -> CFDataRef;
    pub fn CFPropertyListCreateDeepCopy(
        allocator: CFAllocatorRef,
        propertyList: CFPropertyListRef,
        mutabilityOption: c_int,
    ) -> CFPropertyListRef;

    pub fn CFDictionaryCreateMutable(
        allocator: CFAllocatorRef,
        capacity: CFIndex,
        keyCallBacks: *const c_void,
        valueCallBacks: *const c_void,
    ) -> CFDictionaryRef;
    pub fn CFDictionaryGetCount(theDict: CFDictionaryRef) -> CFIndex;
    pub fn CFDictionaryGetValue(theDict: CFDictionaryRef, key: *const c_void) -> *const c_void;
    pub fn CFDictionaryGetKeysAndValues(
        theDict: CFDictionaryRef,
        keys: *mut *const c_void,
        values: *mut *const c_void,
    );
    pub fn CFDictionaryAddValue(
        theDict: CFDictionaryRef,
        key: *const c_void,
        value: *const c_void,
    );
    pub fn CFDictionarySetValue(
        theDict: CFDictionaryRef,
        key: *const c_void,
        value: *const c_void,
    );
    pub fn CFDictionaryReplaceValue(
        theDict: CFDictionaryRef,
        key: *const c_void,
        value: *const c_void,
    );
    pub fn CFDictionaryRemoveValue(theDict: CFDictionaryRef, key: *const c_void);

    pub fn CFArrayCreateMutable(
        allocator: CFAllocatorRef,
        capacity: CFIndex,
        callBacks: *const c_void,
    ) -> CFArrayRef;
    pub fn CFArrayGetCount(theArray: CFArrayRef) -> CFIndex;
    pub fn CFArrayGetValueAtIndex(theArray: CFArrayRef, idx: CFIndex) -> *const c_void;
    pub fn CFArraySetValueAtIndex(theArray: CFArrayRef, idx: CFIndex, value: *const c_void);
    pub fn CFArrayInsertValueAtIndex(theArray: CFArrayRef, idx: CFIndex, value: *const c_void);
    pub fn CFArrayAppendValue(theArray: CFArrayRef, value: *const c_void);
    pub fn CFArrayRemoveValueAtIndex(theArray: CFArrayRef, idx: CFIndex);
    pub fn CFArrayAppendArray(theArray: CFArrayRef, otherArray: CFArrayRef, otherRange: CFRange);
    pub fn CFArrayReplaceValues(
        theArray: CFArrayRef,
        range: CFRange,
        newValues: *const *const c_void,
        newCount: CFIndex,
    );

    pub fn CFNumberCreate(
        allocator: CFAllocatorRef,
        theType: c_int,
        valuePtr: *const c_void,
    ) -> CFNumberRef;
    pub fn CFNumberGetValue(number: CFNumberRef, theType: c_int, valuePtr: *mut c_void) -> bool;
    pub fn CFNumberIsFloatType(number: CFNumberRef) -> bool;

    pub fn CFDataCreate(allocator: CFAllocatorRef, bytes: *const UInt8, length: CFIndex)
        -> CFDataRef;
    pub fn CFDataGetBytePtr(theData: CFDataRef) -> *const UInt8;
    pub fn CFDataGetLength(theData: CFDataRef) -> CFIndex;

    pub fn CFDateCreate(allocator: CFAllocatorRef, at: CFAbsoluteTime) -> CFDateRef;
    pub fn CFDateGetAbsoluteTime(theDate: CFDateRef) -> CFAbsoluteTime;
    pub fn CFTimeZoneCopyDefault() -> CFTimeZoneRef;
    pub fn CFGregorianDateGetAbsoluteTime(gdate: CFGregorianDate, tz: CFTimeZoneRef)
        -> CFAbsoluteTime;
    pub fn CFAbsoluteTimeGetGregorianDate(at: CFAbsoluteTime, tz: CFTimeZoneRef)
        -> CFGregorianDate;
    pub fn CFAbsoluteTimeGetDayOfWeek(at: CFAbsoluteTime, tz: CFTimeZoneRef) -> SInt32;

    // libc. Output goes through these so the formatting and the buffering are the C ones.
    pub fn printf(fmt: *const c_char, ...) -> c_int;
    pub fn puts(s: *const c_char) -> c_int;
    pub fn fwrite(ptr: *const c_void, size: usize, nmemb: usize, stream: *mut c_void) -> usize;
    pub fn fgets(s: *mut c_char, size: c_int, stream: *mut c_void) -> *mut c_char;
    pub fn exit(status: c_int) -> !;
    pub fn access(path: *const c_char, mode: c_int) -> c_int;
    pub fn strtoll(nptr: *const c_char, endptr: *mut *mut c_char, base: c_int) -> i64;
    pub fn strtod(nptr: *const c_char, endptr: *mut *mut c_char) -> c_double;
    pub fn strptime(s: *const c_char, format: *const c_char, tm: *mut tm) -> *mut c_char;
    pub fn strftime(s: *mut c_char, maxsize: usize, format: *const c_char, tm: *const tm)
        -> usize;

    // __stdinp and __stdoutp are the Darwin names; there is no `stdin` symbol to link against.
    pub static mut __stdinp: *mut c_void;
    pub static mut __stdoutp: *mut c_void;
}
