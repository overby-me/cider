/*
This file is part of Darling.

Copyright (C) 2017 Lubos Dolezel
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

//! PlistBuddy, ported from PlistBuddy.c (#102).
//!
//! WHY THIS IS A PORT WORTH MAKING, from the measurement in docs/changelog.md rather than from taste: only
//! 17 percent of the C touches CoreFoundation. The other 83 percent is string parsing, a command
//! loop, type inference and a hand-rolled pretty printer, over user input, with 64 lines of
//! malloc, free, strdup, strndup and alloca. That is the part this rewrite makes safe. The CF
//! calls stay unsafe externs and gain nothing, and pretending otherwise would be dishonest.
//!
//! WHAT IS DELIBERATELY NOT IMPROVED. This is a parity port, so upstream behaviour is reproduced
//! including the parts that are plainly wrong, each marked UPSTREAM BUG below. Fixing them here
//! would make the gate red for the right reason and the tool wrong for the user, who has scripts.
//!
//! THE ONE PLACE PARITY CANNOT BE PROMISED is the date parser, and it is upstream's fault: the C
//! declares `struct tm tm;` uninitialized and calls strptime, which only writes the fields its
//! format matched. With "%D" the time fields are read back as whatever was on the stack. The C
//! is therefore not deterministic there either. This zero-initializes, which is the only defined
//! choice, and the gate does not claim a byte match for that input.

#![allow(non_snake_case)]

// THE CoreFoundation SURFACE, INLINE RATHER THAN IN cf.rs, and that is forced rather than
// chosen: a `mod` in its own file is a HIDDEN input, buck2 aquery reports no input list, and
// the Nix endpoint stages only what the argv names. As a separate file this crate built
// under buck2 and died in the lowering with 205 errors, the first being
// "file not found for module cf". See buck/rules/rust.bzl.
mod cf {
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

}

use cf::*;
use core::ffi::{c_char, c_int, c_void};
use core::ptr::{null, null_mut};

// ---------------------------------------------------------------------------------------------
// Global state, exactly the three globals the C has. A parity port that reorganised this into an
// argument-threaded design would be a rewrite, and every difference would then need arguing.

static mut PLIST: CFPropertyListRef = null();
static mut OUTPUT_FILE: Option<Vec<u8>> = None;
static mut FORCE_XML: bool = false;

fn plist() -> CFPropertyListRef {
    unsafe { PLIST }
}

fn output_file() -> Option<&'static [u8]> {
    unsafe { (*(&raw const OUTPUT_FILE)).as_deref() }
}

// ---------------------------------------------------------------------------------------------
// Output. Everything goes through C stdio, so formatting and buffering are not reimplemented.

/// A NUL-terminated copy, which is what every C boundary here wants.
fn cstr(b: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(b.len() + 1);
    v.extend_from_slice(b);
    v.push(0);
    v
}

/// printf("%s", ...) for bytes we own. fwrite shares stdout's FILE with printf, so mixing them
/// cannot reorder output.
fn out(b: &[u8]) {
    if b.is_empty() {
        return;
    }
    unsafe {
        fwrite(b.as_ptr() as *const c_void, 1, b.len(), __stdoutp);
    }
}

/// puts(): the string then a newline.
fn outln(b: &[u8]) {
    out(b);
    out(b"\n");
}

fn out_cstr_ptr(p: *const c_char) {
    // THE POINTER IS PASSED STRAIGHT TO printf, NULL AND ALL. CFStringGetCStringPtr returns NULL
    // when the string has no UTF-8 backing store, and the C prints "(null)" there. Testing for
    // null and printing nothing would be tidier and would not match.
    unsafe {
        printf(c"%s".as_ptr(), p);
    }
}

// ---------------------------------------------------------------------------------------------
// CoreFoundation helpers used all over the port.

unsafe fn cf_string(b: &[u8]) -> CFStringRef {
    let z = cstr(b);
    unsafe { CFStringCreateWithCString(kCFAllocatorDefault, z.as_ptr() as *const c_char, kCFStringEncodingUTF8) }
}

unsafe fn new_dict() -> CFPropertyListRef {
    unsafe {
        CFDictionaryCreateMutable(
            kCFAllocatorDefault,
            0,
            &raw const kCFTypeDictionaryKeyCallBacks,
            &raw const kCFTypeDictionaryValueCallBacks,
        )
    }
}

/// atoi() on a byte slice: leading space, optional sign, decimal digits, stop at the first thing
/// that is not one. Saturating rather than wrapping, which only differs for input C would have
/// made undefined anyway.
fn atoi(b: &[u8]) -> i64 {
    let mut i = 0;
    while i < b.len() && (b[i] as char).is_ascii_whitespace() {
        i += 1;
    }
    let neg = if i < b.len() && (b[i] == b'-' || b[i] == b'+') {
        let n = b[i] == b'-';
        i += 1;
        n
    } else {
        false
    };
    let mut v: i64 = 0;
    while i < b.len() && b[i].is_ascii_digit() {
        v = v.saturating_mul(10).saturating_add((b[i] - b'0') as i64);
        i += 1;
    }
    if neg { -v } else { v }
}

fn eq_ignore_case(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.eq_ignore_ascii_case(y))
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum PropertyType {
    Unknown,
    String,
    Array,
    Dict,
    Bool,
    Real,
    Integer,
    Date,
    Data,
}

// ---------------------------------------------------------------------------------------------

fn printUsage() {
    outln(
        b"Usage: PlistBuddy [-cxh] <file.plist>\n\
        \x20   -c \"<command>\" execute command, otherwise run in interactive mode\n\
        \x20   -x output will be in the form of an xml plist where appropriate\n\
        \x20   -h print the complete help info, with command guide\n",
    );
}

fn printHelp() {
    outln(
        b"Command Format:\n\n\
\x20   Help - Prints this information\n\
\x20   Exit - Exits the program, changes are not saved to the file\n\
\x20   Save - Saves the current changes to the file\n\
\x20   Revert - Reloads the last saved version of the file\n\
\x20   Clear [<Type>] - Clears out all existing entries, and creates root of Type\n\
\x20   Print [<Entry>] - Prints value of Entry.  Otherwise, prints file\n\
\x20   Set <Entry> <Value> - Sets the value at Entry to Value\n\
\x20   Add <Entry> <Type> [<Value>] - Adds Entry to the plist, with value Value\n\
\x20   Copy <EntrySrc> <EntryDst> - Copies the EntrySrc property to EntryDst\n\
\x20   Delete <Entry> - Deletes Entry from the plist\n\
\x20   Merge <file.plist> [<Entry>] - Adds the contents of file.plist to Entry\n\
\x20   Import <Entry> <file> - Creates or sets Entry the contents of file\n\
\n\
Entry Format:\n\
\x20   Entries consist of property key names delimited by colons.  Array items\n\
\x20   are specified by a zero-based integer index.  Examples:\n\
\x20       :CFBundleShortVersionString\n\
\x20       :CFBundleDocumentTypes:2:CFBundleTypeExtensions\n\
\n\
Types:\n\
\x20   string\n\
\x20   array\n\
\x20   dict\n\
\x20   bool\n\
\x20   real\n\
\x20   integer\n\
\x20   date\n\
\x20   data\n\
\n\
Examples:\n\
\x20   Set :CFBundleIdentifier com.apple.plistbuddy\n\
\x20       Sets the CFBundleIdentifier property to com.apple.plistbuddy\n\
\x20   Add :CFBundleGetInfoString string \"App version 1.0.1\"\n\
\x20       Adds the CFBundleGetInfoString property to the plist\n\
\x20   Add :CFBundleDocumentTypes: dict\n\
\x20       Adds a new item of type dict to the CFBundleDocumentTypes array\n\
\x20   Add :CFBundleDocumentTypes:0 dict\n\
\x20       Adds the new item to the beginning of the array\n\
\x20   Delete :CFBundleDocumentTypes:0 dict\n\
\x20       Deletes the FIRST item in the array\n\
\x20   Delete :CFBundleDocumentTypes\n\
\x20       Deletes the ENTIRE CFBundleDocumentTypes array\n",
    );
}

/// Returns (ok, command). The C signature returns a bool and writes the command through a
/// pointer, and the SHAPE of the result matters: false means print usage and exit 1, true with
/// no output file means exit 0, which is the -h path.
fn processArgs(argv: &[&[u8]]) -> (bool, Option<Vec<u8>>) {
    if argv.len() <= 1 {
        return (false, None);
    }
    let mut command: Option<Vec<u8>> = None;
    let mut i = 1;
    while i < argv.len() {
        if argv[i] == b"-c" {
            if i + 1 >= argv.len() {
                return (false, None);
            }
            i += 1;
            command = Some(argv[i].to_vec());
        } else if argv[i] == b"-x" {
            unsafe { FORCE_XML = true };
        } else if argv[i] == b"-h" {
            printHelp();
            return (true, command);
        } else if i + 1 >= argv.len() {
            unsafe { OUTPUT_FILE = Some(argv[i].to_vec()) };
        } else {
            outln(b"Invalid Arguments");
            unsafe { exit(1) };
        }
        i += 1;
    }
    (output_file().is_some(), command)
}

unsafe fn loadPlist(filePath: &[u8]) -> CFPropertyListRef {
    unsafe {
        let mut errorCode: SInt32 = 0;
        let mut errorString: CFStringRef = null();
        let mut data: CFDataRef = null();

        let path = cf_string(filePath);
        let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path, kCFURLPOSIXPathStyle, false);
        CFRelease(path);

        CFURLCreateDataAndPropertiesFromResource(
            kCFAllocatorDefault,
            url,
            &mut data,
            null_mut(),
            null(),
            &mut errorCode,
        );
        CFRelease(url);

        if errorCode != 0 {
            out(b"Error Reading File: ");
            out(filePath);
            out(b"\n");
            // UPSTREAM BUG kept: the C writes `return false` from a pointer-returning function,
            // so this returns NULL and the leaked CFData is upstream's too.
            return null();
        }

        let plist = CFPropertyListCreateFromXMLData(
            kCFAllocatorDefault,
            data,
            kCFPropertyListMutableContainers,
            &mut errorString,
        );

        if !errorString.is_null() {
            CFShow(errorString);
            CFRelease(errorString);
            out(b"Error Reading File: ");
            out(filePath);
            out(b"\n");
        }

        plist
    }
}

unsafe fn revertToFile() -> bool {
    unsafe {
        if !PLIST.is_null() {
            CFRelease(PLIST);
        }
        let file = output_file().unwrap_or(b"");
        let z = cstr(file);
        if access(z.as_ptr() as *const c_char, F_OK) != 0 {
            out(b"File Doesn't Exist, Will Create: ");
            out(file);
            out(b"\n");
            PLIST = new_dict();
            true
        } else {
            PLIST = loadPlist(file);
            let rv = !PLIST.is_null();
            if PLIST.is_null() {
                PLIST = new_dict();
            }
            rv
        }
    }
}

unsafe fn saveToFile() -> bool {
    unsafe {
        let mut rv = true;
        let file = output_file().unwrap_or(b"");
        let path = cf_string(file);
        let url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, path, kCFURLPOSIXPathStyle, false);
        CFRelease(path);

        let data = CFPropertyListCreateXMLData(kCFAllocatorDefault, PLIST);
        if !data.is_null() {
            let mut errorCode: SInt32 = 0;
            CFURLWriteDataAndPropertiesToResource(url, data, null(), &mut errorCode);
            CFRelease(data);
            if errorCode != 0 {
                outln(b"Cannot Write File");
                rv = false;
            }
        } else {
            outln(b"Cannot Format Plist");
            rv = false;
        }

        CFRelease(url);
        rv
    }
}

/// The C returns a pointer to the first non-space, or NULL when only spaces remain. Here that is
/// an index into the same slice, and None for the NULL.
fn nextWord(input: &[u8]) -> Option<usize> {
    let mut i = 0;
    while i < input.len() && (input[i] as char).is_ascii_whitespace() {
        i += 1;
    }
    if i < input.len() { Some(i) } else { None }
}

/// isCommand: a case-insensitive prefix that must be followed by a space or the end.
fn isCommand<'a>(input: &'a [u8], cmd: &[u8]) -> Option<Option<&'a [u8]>> {
    let len = cmd.len();
    if input.len() >= len
        && eq_ignore_case(&input[..len], cmd)
        && (input.len() == len || input[len] == b' ')
    {
        let rest = &input[len..];
        Some(nextWord(rest).map(|i| &rest[i..]))
    } else {
        None
    }
}

fn parseType(t: &[u8]) -> PropertyType {
    if eq_ignore_case(t, b"string") {
        PropertyType::String
    } else if eq_ignore_case(t, b"array") {
        PropertyType::Array
    } else if eq_ignore_case(t, b"dict") {
        PropertyType::Dict
    } else if eq_ignore_case(t, b"bool") {
        PropertyType::Bool
    } else if eq_ignore_case(t, b"real") {
        PropertyType::Real
    } else if eq_ignore_case(t, b"integer") {
        PropertyType::Integer
    } else if eq_ignore_case(t, b"date") {
        PropertyType::Date
    } else if eq_ignore_case(t, b"data") {
        PropertyType::Data
    } else {
        out(b"Unrecognized Type: ");
        out(t);
        out(b"\n");
        PropertyType::Unknown
    }
}

unsafe fn inferType(obj: CFPropertyListRef) -> PropertyType {
    unsafe {
        let typeId = CFGetTypeID(obj);
        if typeId == CFStringGetTypeID() {
            PropertyType::String
        } else if typeId == CFArrayGetTypeID() {
            PropertyType::Array
        } else if typeId == CFDictionaryGetTypeID() {
            PropertyType::Dict
        } else if typeId == CFBooleanGetTypeID() {
            PropertyType::Bool
        } else if typeId == CFNumberGetTypeID() {
            if CFNumberIsFloatType(obj) { PropertyType::Real } else { PropertyType::Integer }
        } else if typeId == CFDateGetTypeID() {
            PropertyType::Date
        } else if typeId == CFDataGetTypeID() {
            PropertyType::Data
        } else {
            PropertyType::Unknown
        }
    }
}

/// getWord: one argument, quoted or not, with the C's escape handling.
///
/// Returns the word and the rest of the line. None means the quotes were unterminated, which the
/// C reports and treats as a failed command.
fn getWord<'a>(cmd: &'a [u8]) -> Option<(Vec<u8>, Option<&'a [u8]>)> {
    if !cmd.is_empty() && cmd[0] == b'"' {
        let mut outv: Vec<u8> = Vec::new();
        let mut closed = false;
        let mut i = 1usize;
        while i < cmd.len() {
            if cmd[i] == b'\\' && i + 1 < cmd.len() {
                i += 1;
                match cmd[i] {
                    b'"' => outv.push(b'"'),
                    b'n' => outv.push(b'\n'),
                    b't' => outv.push(b'\t'),
                    c => {
                        outv.push(b'\\');
                        outv.push(c);
                    }
                }
            } else if cmd[i] == b'"' {
                closed = true;
                break;
            } else {
                outv.push(cmd[i]);
            }
            i += 1;
        }
        // The C decides this by looking for the NUL it wrote into its own buffer: an empty word
        // is accepted (j == 0) and a non-empty unterminated one is not.
        if !closed && !outv.is_empty() {
            outln(b"Unterminated Quotes");
            return None;
        }
        let rest = if i + 1 <= cmd.len() { &cmd[core::cmp::min(i + 1, cmd.len())..] } else { &cmd[cmd.len()..] };
        Some((outv, nextWord(rest).map(|k| &rest[k..])))
    } else {
        match cmd.iter().position(|&c| c == b' ') {
            None => Some((cmd.to_vec(), None)),
            Some(p) => {
                let rest = &cmd[p..];
                Some((cmd[..p].to_vec(), nextWord(rest).map(|k| &rest[k..])))
            }
        }
    }
}

unsafe fn runCommand(cmd: &[u8]) {
    unsafe {
        if isCommand(cmd, b"Exit").is_some()
            || isCommand(cmd, b"Quit").is_some()
            || isCommand(cmd, b"Bye").is_some()
        {
            exit(0);
        } else if isCommand(cmd, b"Help").is_some() {
            printHelp();
        } else if isCommand(cmd, b"Save").is_some() {
            outln(b"Saving...");
            saveToFile();
        } else if isCommand(cmd, b"Revert").is_some() {
            outln(b"Reverting to last saved state...");
            revertToFile();
        } else if let Some(next) = isCommand(cmd, b"Print").or_else(|| isCommand(cmd, b"ls")) {
            doPrint(next);
        } else if let Some(next) = isCommand(cmd, b"Clear") {
            // UPSTREAM BUG kept: Clear parses its type and then does nothing at all. The plist is
            // not cleared and no root is created. Reproduced because scripts may rely on it being
            // a no-op, and because a gate on the written file would catch a "fix" as a difference.
            let mut _type = PropertyType::Unknown;
            if let Some(n) = next {
                _type = parseType(n);
            }
            if _type == PropertyType::Unknown {
                _type = PropertyType::Dict;
            }
        } else if let Some(next) = isCommand(cmd, b"Set").or_else(|| isCommand(cmd, b"=")) {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            let Some((entry, rest)) = getWord(next) else { return };
            setEntry(&entry, rest.unwrap_or(b""));
        } else if let Some(next) = isCommand(cmd, b"Add").or_else(|| isCommand(cmd, b"+")) {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            let Some((entry, rest)) = getWord(next) else { return };
            let Some(rest) = rest else {
                outln(b"Missing arguments");
                return;
            };
            let Some((ty, rest2)) = getWord(rest) else { return };
            let typeV = parseType(&ty);
            if typeV == PropertyType::Unknown {
                return;
            }
            addEntry(&entry, typeV, rest2.unwrap_or(b""));
        } else if let Some(next) = isCommand(cmd, b"Copy").or_else(|| isCommand(cmd, b"cp")) {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            let Some((src, rest)) = getWord(next) else { return };
            let Some(rest) = rest else {
                outln(b"Missing arguments");
                return;
            };
            let Some((dst, _)) = getWord(rest) else { return };
            copyEntry(&src, &dst);
        } else if let Some(next) = isCommand(cmd, b"Delete")
            .or_else(|| isCommand(cmd, b"rm"))
            .or_else(|| isCommand(cmd, b"-"))
        {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            // The C passes `next` whole, NOT a parsed word, so a quoted entry keeps its quotes.
            deleteEntry(next);
        } else if let Some(next) = isCommand(cmd, b"Merge") {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            let Some((path, rest)) = getWord(next) else { return };
            mergeFile(&path, rest);
        } else if let Some(next) = isCommand(cmd, b"Import") {
            let Some(next) = next else {
                outln(b"Missing arguments");
                return;
            };
            let Some((entry, rest)) = getWord(next) else { return };
            let Some(rest) = rest else {
                outln(b"Missing arguments");
                return;
            };
            let Some((path, _)) = getWord(rest) else { return };
            importFile(&entry, &path);
        } else {
            outln(b"Unrecognized Command");
        }
    }
}

unsafe fn addEntry(entry: &[u8], ty: PropertyType, value: &[u8]) {
    unsafe {
        let newValue = if ty == PropertyType::Array {
            CFArrayCreateMutable(kCFAllocatorDefault, 0, &raw const kCFTypeArrayCallBacks)
        } else if ty == PropertyType::Dict {
            new_dict()
        } else {
            let v = parseValue(ty, value);
            if v.is_null() {
                return;
            }
            v
        };

        let (parent, existing, leafName) = resolvePlistEntry(entry, true);

        if parent.is_null() {
            out(b"Add: Entry, \"");
            out(entry);
            out(b"\", Does Not Exist\n");
            return;
        }

        let parentType = CFGetTypeID(parent);

        // For arrays we insert at the given position, so an existing entry is not a clash.
        if !existing.is_null() && parentType != CFArrayGetTypeID() {
            out(b"Add: \"");
            out(entry);
            out(b"\" Entry Already Exists\n");
            CFRelease(newValue);
            return;
        }

        if parentType == CFArrayGetTypeID() {
            let mut index = atoi(&leafName) as CFIndex;
            let count = CFArrayGetCount(parent);
            if index < 0 {
                index = 0;
            } else if index > count {
                index = count;
            }
            CFArrayInsertValueAtIndex(parent, index, newValue);
        } else if parentType == CFDictionaryGetTypeID() {
            let key = cf_string(&leafName);
            CFDictionaryAddValue(parent, key, newValue);
            CFRelease(key);
        } else {
            out(b"Add: Can't Add Entry, \"");
            out(entry);
            out(b"\", to Parent\n");
        }

        CFRelease(newValue);
    }
}

unsafe fn parseValue(ty: PropertyType, string: &[u8]) -> CFPropertyListRef {
    unsafe {
        match ty {
            PropertyType::String | PropertyType::Data => {
                let hasQuotes = !string.is_empty() && string[0] == b'"';
                let mut i = 0usize;
                let mut len = string.len();

                if hasQuotes {
                    if string[len - 1] != b'"' {
                        outln(b"Parse Error: Unclosed Quotes");
                        return null();
                    }
                    i += 1;
                    len -= 1;
                }

                let mut stringOut: Vec<u8> = Vec::with_capacity(len);
                while i < len {
                    if string[i] != b'\\' {
                        stringOut.push(string[i]);
                    } else {
                        if i + 1 == len {
                            outln(b"Parse Error: Unclosed Quotes");
                            return null();
                        }
                        i += 1;
                        match string[i] {
                            b'"' => stringOut.push(b'"'),
                            b'n' => stringOut.push(b'\n'),
                            b't' => stringOut.push(b'\t'),
                            c => stringOut.push(c),
                        }
                    }
                    i += 1;
                }

                if ty == PropertyType::String {
                    cf_string(&stringOut)
                } else {
                    // UPSTREAM BUG kept: data takes the ORIGINAL argument, quotes, escapes and
                    // all, not the unescaped copy it just built.
                    CFDataCreate(kCFAllocatorDefault, string.as_ptr(), string.len() as CFIndex)
                }
            }
            PropertyType::Bool => {
                if eq_ignore_case(string, b"true") || eq_ignore_case(string, b"yes") || string == b"1" {
                    kCFBooleanTrue
                } else {
                    kCFBooleanFalse
                }
            }
            PropertyType::Integer => {
                let z = cstr(string);
                let mut endptr: *mut c_char = null_mut();
                let v = strtoll(z.as_ptr() as *const c_char, &mut endptr, 0);
                if endptr as *const c_char == z.as_ptr() as *const c_char {
                    outln(b"Unrecognized Integer Format");
                    return null();
                }
                CFNumberCreate(
                    kCFAllocatorDefault,
                    kCFNumberLongLongType,
                    &v as *const i64 as *const c_void,
                )
            }
            PropertyType::Real => {
                let z = cstr(string);
                let mut endptr: *mut c_char = null_mut();
                let v = strtod(z.as_ptr() as *const c_char, &mut endptr);
                if endptr as *const c_char == z.as_ptr() as *const c_char {
                    outln(b"Unrecognized Real Format");
                    return null();
                }
                CFNumberCreate(
                    kCFAllocatorDefault,
                    kCFNumberFloat64Type,
                    &v as *const f64 as *const c_void,
                )
            }
            PropertyType::Date => {
                // See the module header: the C reads an UNINITIALIZED struct tm back after
                // strptime, so for a format that matches only some fields it is undefined there.
                // Zero is the only defined choice.
                let mut t = tm::default();
                let z = cstr(string);
                let ok = !strptime(z.as_ptr() as *const c_char, c"%a %b %d %H:%M:%S %Z %Y".as_ptr(), &mut t).is_null()
                    || !strptime(z.as_ptr() as *const c_char, c"%c".as_ptr(), &mut t).is_null()
                    || !strptime(z.as_ptr() as *const c_char, c"%D".as_ptr(), &mut t).is_null();
                if !ok {
                    outln(b"Unrecognized Date Format");
                    return null();
                }

                let tz = CFTimeZoneCopyDefault();
                let date = CFGregorianDate {
                    year: t.tm_year + 1900,
                    month: (t.tm_mon + 1) as i8,
                    day: t.tm_mday as i8,
                    hour: t.tm_hour as i8,
                    minute: t.tm_min as i8,
                    second: t.tm_sec as f64,
                };
                let at = CFGregorianDateGetAbsoluteTime(date, tz);
                let rv = CFDateCreate(kCFAllocatorDefault, at);
                CFRelease(tz);
                rv
            }
            _ => {
                outln(b"Cannot parse this entry type");
                null()
            }
        }
    }
}

unsafe fn setEntry(entry: &[u8], entryValue: &[u8]) {
    unsafe {
        let (parent, existing, leafName) = resolvePlistEntry(entry, false);
        if existing.is_null() {
            out(b"Set: Entry, \"");
            out(entry);
            out(b"\", Does Not Exist\n");
            return;
        }

        let ty = inferType(existing);
        if ty == PropertyType::Array || ty == PropertyType::Dict {
            outln(b"Set: Cannot Perform Set On Containers");
            return;
        }

        let newValue = parseValue(ty, entryValue);
        if newValue.is_null() {
            return;
        }

        if CFGetTypeID(parent) == CFDictionaryGetTypeID() {
            let leafNameStr = cf_string(&leafName);
            CFDictionaryReplaceValue(parent, leafNameStr, newValue);
            CFRelease(leafNameStr);
        } else {
            let index = atoi(&leafName) as CFIndex;
            CFArraySetValueAtIndex(parent, index, newValue);
        }

        CFRelease(newValue);
    }
}

/// The C walks the entry path with a strtok that keeps empty tokens, and the exact shape decides
/// what `parent` comes out as, so this reproduces the loop rather than tidying it:
///   the head and tail colons are trimmed first;
///   runs of colons collapse, because the tokenizer skips leading delimiters;
///   an empty path yields ONE empty token, which leaves pos at the root;
///   `parent` is the previous position ONLY if the walk ran out of tokens, and NULL if it
///   stopped because a lookup failed. That distinction is what makes Add report a missing parent.
unsafe fn resolvePlistEntry(
    whatStr: &[u8],
    autoCreate: bool,
) -> (CFPropertyListRef, CFPropertyListRef, Vec<u8>) {
    unsafe {
        let mut pos: CFPropertyListRef = PLIST;
        let mut lastPos: CFPropertyListRef = null();
        let mut lastTok: Vec<u8> = Vec::new();

        let mut s = whatStr;
        while !s.is_empty() && s[0] == b':' {
            s = &s[1..];
        }
        let mut len = s.len();
        while len > 0 && s[len - 1] == b':' {
            len -= 1;
        }
        let buf = &s[..len];

        let mut p: Option<usize> = Some(0);
        let mut ran_out = false;
        loop {
            let tok: &[u8] = match p {
                None => {
                    ran_out = true;
                    break;
                }
                Some(mut i) => {
                    while i < buf.len() && buf[i] == b':' {
                        i += 1;
                    }
                    let start = i;
                    match buf[start..].iter().position(|&c| c == b':') {
                        Some(off) => {
                            let end = start + off;
                            p = Some(end + 1);
                            &buf[start..end]
                        }
                        None => {
                            p = None;
                            &buf[start..]
                        }
                    }
                }
            };
            if pos.is_null() {
                break;
            }

            lastPos = pos;
            if !tok.is_empty() {
                let typeId = CFGetTypeID(pos);
                if typeId == CFDictionaryGetTypeID() {
                    let key = cf_string(tok);
                    pos = CFDictionaryGetValue(pos, key);
                    if pos.is_null() && autoCreate && p.is_some() {
                        pos = new_dict();
                        CFDictionaryAddValue(lastPos, key, pos);
                    }
                    CFRelease(key);
                } else if typeId == CFArrayGetTypeID() {
                    let index = atoi(tok) as CFIndex;
                    if index < 0 || index >= CFArrayGetCount(pos) {
                        pos = null();
                    } else {
                        pos = CFArrayGetValueAtIndex(pos, index);
                    }
                } else {
                    pos = null();
                }
            }
            lastTok = tok.to_vec();
        }

        let parent = if ran_out { lastPos } else { null() };
        (parent, pos, lastTok)
    }
}

unsafe fn prettyPrintPlist(what: CFPropertyListRef, indentNum: usize) {
    unsafe {
        let typeId = CFGetTypeID(what);
        let indent = vec![b' '; indentNum];

        if typeId == CFStringGetTypeID() {
            out_cstr_ptr(CFStringGetCStringPtr(what, kCFStringEncodingUTF8));
        } else if typeId == CFArrayGetTypeID() {
            let count = CFArrayGetCount(what);
            out(b"Array {\n");
            for i in 0..count {
                let elem = CFArrayGetValueAtIndex(what, i);
                out(&indent);
                out(b"    ");
                prettyPrintPlist(elem, indentNum + 4);
                out(b"\n");
            }
            out(&indent);
            out(b"}");
        } else if typeId == CFDictionaryGetTypeID() {
            let count = CFDictionaryGetCount(what) as usize;
            let mut keys: Vec<*const c_void> = vec![null(); count];
            let mut values: Vec<*const c_void> = vec![null(); count];
            CFDictionaryGetKeysAndValues(what, keys.as_mut_ptr(), values.as_mut_ptr());

            out(b"Dict {\n");
            for i in 0..count {
                out(&indent);
                out(b"    ");
                prettyPrintPlist(keys[i], 0);
                out(b" = ");
                prettyPrintPlist(values[i], indentNum + 4);
                out(b"\n");
            }
            out(&indent);
            out(b"}");
        } else if typeId == CFBooleanGetTypeID() {
            if what == kCFBooleanTrue {
                out(b"true");
            } else {
                out(b"false");
            }
        } else if typeId == CFNumberGetTypeID() {
            // printf DOES THE FORMATTING, both here and in the C: %f is six decimal places and
            // Rust would print 3.14 where C prints 3.140000.
            if CFNumberIsFloatType(what) {
                let mut d: f64 = 0.0;
                CFNumberGetValue(what, kCFNumberFloat64Type, &mut d as *mut f64 as *mut c_void);
                printf(c"%f".as_ptr(), d);
            } else {
                let mut l: i64 = 0;
                CFNumberGetValue(what, kCFNumberLongLongType, &mut l as *mut i64 as *mut c_void);
                printf(c"%lld".as_ptr(), l);
            }
        } else if typeId == CFDateGetTypeID() {
            let t = CFDateGetAbsoluteTime(what);
            let tz = CFTimeZoneCopyDefault();
            let d = CFAbsoluteTimeGetGregorianDate(t, tz);
            let mut tmv = tm::default();
            let mut buf = [0i8; 150];

            tmv.tm_mday = d.day as c_int;
            tmv.tm_mon = (d.month - 1) as c_int;
            tmv.tm_year = d.year - 1900;
            tmv.tm_hour = d.hour as c_int;
            tmv.tm_min = d.minute as c_int;
            tmv.tm_sec = d.second as c_int;
            tmv.tm_wday = CFAbsoluteTimeGetDayOfWeek(t, tz) as c_int;
            if tmv.tm_wday == 7 {
                tmv.tm_wday = 0;
            }
            tmv.tm_zone = null_mut();
            tmv.tm_isdst = 0;

            strftime(
                buf.as_mut_ptr() as *mut c_char,
                buf.len(),
                c"%a %b %d %H:%M:%S %Z %Y".as_ptr(),
                &tmv,
            );
            printf(c"%s".as_ptr(), buf.as_ptr() as *const c_char);
            CFRelease(tz);
        } else if typeId == CFDataGetTypeID() {
            let bytes = CFDataGetBytePtr(what);
            let len = CFDataGetLength(what);
            fwrite(bytes as *const c_void, 1, len as usize, __stdoutp);
        }
    }
}

unsafe fn doPrint(whatStr: Option<&[u8]>) {
    unsafe {
        let mut entry = PLIST;

        if let Some(w) = whatStr {
            let (_, e, _) = resolvePlistEntry(w, false);
            entry = e;
            if entry.is_null() {
                out(b"Print: Entry, \"");
                out(w);
                out(b"\", Does Not Exist\n");
                return;
            }
        }

        if !FORCE_XML {
            prettyPrintPlist(entry, 0);
            out(b"\n");
        } else {
            let data = CFPropertyListCreateXMLData(kCFAllocatorDefault, entry);
            if !data.is_null() {
                prettyPrintPlist(data, 0);
                out(b"\n");
                CFRelease(data);
            }
        }
    }
}

unsafe fn deleteEntry(entry: &[u8]) {
    unsafe {
        let (parent, existing, leafName) = resolvePlistEntry(entry, false);
        if existing.is_null() {
            out(b"Delete: Entry, \"");
            out(entry);
            out(b"\", Does Not Exist\n");
            return;
        }

        let typeID = CFGetTypeID(parent);
        if typeID == CFDictionaryGetTypeID() {
            let s = cf_string(&leafName);
            CFDictionaryRemoveValue(parent, s);
            CFRelease(s);
        } else {
            let idx = atoi(&leafName) as CFIndex;
            CFArrayRemoveValueAtIndex(parent, idx);
        }
    }
}

unsafe fn copyEntry(src: &[u8], dst: &[u8]) {
    unsafe {
        let (_, entry, _) = resolvePlistEntry(src, false);
        let (newParent, existing, leafName) = resolvePlistEntry(dst, true);

        if entry.is_null() {
            out(b"Copy: Entry, \"");
            out(src);
            out(b"\", Does Not Exist\n");
            return;
        }
        if !existing.is_null() {
            out(b"Copy: \"");
            out(dst);
            out(b"\" Entry Already Exists\n");
            return;
        }

        let entryCopy =
            CFPropertyListCreateDeepCopy(kCFAllocatorDefault, entry, kCFPropertyListMutableContainers);

        let typeID = CFGetTypeID(newParent);
        if typeID == CFDictionaryGetTypeID() {
            let s = cf_string(&leafName);
            CFDictionaryAddValue(newParent, s, entryCopy);
            CFRelease(s);
        } else {
            let idx = atoi(&leafName) as CFIndex;
            CFArrayInsertValueAtIndex(newParent, idx, entryCopy);
        }

        CFRelease(entryCopy);
    }
}

unsafe fn mergeFile(path: &[u8], entry: Option<&[u8]>) {
    unsafe {
        let fileContents = loadPlist(path);
        if fileContents.is_null() {
            return;
        }

        let dest;
        match entry {
            Some(e) if !e.is_empty() => {
                let (_, d, _) = resolvePlistEntry(e, true);
                dest = d;
                if dest.is_null() {
                    out(b"Merge: Entry, \"");
                    out(e);
                    out(b"\", Does Not Exist\n");
                    CFRelease(fileContents);
                    return;
                }
            }
            _ => dest = PLIST,
        }

        let typeID = CFGetTypeID(dest);
        let sourceTypeID = CFGetTypeID(fileContents);

        if typeID == CFArrayGetTypeID() {
            if sourceTypeID == CFArrayGetTypeID() {
                CFArrayAppendArray(dest, fileContents, CFRangeMake(0, CFArrayGetCount(fileContents)));
            } else if sourceTypeID == CFDictionaryGetTypeID() {
                let count = CFDictionaryGetCount(fileContents);
                let mut values: Vec<*const c_void> = vec![null(); count as usize];
                CFDictionaryGetKeysAndValues(fileContents, null_mut(), values.as_mut_ptr());
                CFArrayReplaceValues(
                    dest,
                    CFRangeMake(CFArrayGetCount(dest) - 1, 0),
                    values.as_ptr(),
                    count,
                );
            } else {
                CFArrayAppendValue(dest, fileContents);
            }
        } else if typeID == CFDictionaryGetTypeID() {
            if sourceTypeID == CFDictionaryGetTypeID() {
                let count = CFDictionaryGetCount(fileContents) as usize;
                let mut keys: Vec<*const c_void> = vec![null(); count];
                let mut values: Vec<*const c_void> = vec![null(); count];
                CFDictionaryGetKeysAndValues(fileContents, keys.as_mut_ptr(), values.as_mut_ptr());
                for i in 0..count {
                    CFDictionarySetValue(dest, keys[i], values[i]);
                }
            } else if sourceTypeID == CFArrayGetTypeID() {
                outln(b"Merge: Can't Add array Entries to dict");
            } else {
                // CFSTR("") is a MACRO in C, so there is no symbol to call: it becomes a created
                // and released empty CFString here.
                let empty = cf_string(b"");
                CFDictionarySetValue(dest, empty, fileContents);
                CFRelease(empty);
            }
        } else {
            outln(b"Merge: Specified Entry Must Be a Container");
        }

        CFRelease(fileContents);
    }
}

/// NOTE, carried over from the C: this function does not seem to work at all in the original.
unsafe fn importFile(entry: &[u8], path: &[u8]) {
    unsafe {
        let fileContents = loadPlist(path);
        if fileContents.is_null() {
            return;
        }

        let (dest, _, leafName) = resolvePlistEntry(entry, true);
        if dest.is_null() {
            out(b"Import: Entry, \"");
            out(entry);
            out(b"\", Does Not Exist\n");
            CFRelease(fileContents);
            return;
        }

        let typeID = CFGetTypeID(dest);
        if typeID == CFDictionaryGetTypeID() {
            let key = cf_string(&leafName);
            CFDictionarySetValue(dest, key, fileContents);
            CFRelease(key);
        } else if typeID == CFArrayGetTypeID() {
            let mut index = atoi(&leafName) as CFIndex;
            if index < 0 {
                index = 0;
            }
            if index >= CFArrayGetCount(dest) {
                CFArrayAppendValue(dest, fileContents);
            } else {
                CFArraySetValueAtIndex(dest, index, fileContents);
            }
        }

        CFRelease(fileContents);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn main(argc: c_int, argv: *const *const c_char) -> c_int {
    unsafe {
        // argv comes from crt1, not from std::env, because this is a staticlib with a C entry
        // point and because the C reads exactly these pointers.
        let mut args: Vec<&[u8]> = Vec::with_capacity(argc as usize);
        for i in 0..argc as usize {
            let p = *argv.add(i);
            if p.is_null() {
                break;
            }
            let mut n = 0usize;
            while *p.add(n) != 0 {
                n += 1;
            }
            args.push(core::slice::from_raw_parts(p as *const u8, n));
        }

        let (ok, command) = processArgs(&args);
        if !ok {
            printUsage();
            return 1;
        }
        if output_file().is_none() {
            return 0;
        }

        if !revertToFile() {
            return 1;
        }

        if let Some(cmd) = command {
            runCommand(&cmd);
            if !saveToFile() {
                return 1;
            }
        } else {
            loop {
                // 200 bytes, the same buffer the C reads into, so a longer line splits into two
                // commands in both.
                let mut buffer = [0i8; 200];
                out(b"Command: ");
                if fgets(buffer.as_mut_ptr() as *mut c_char, buffer.len() as c_int, __stdinp).is_null() {
                    break;
                }
                let mut n = 0usize;
                while n < buffer.len() && buffer[n] != 0 {
                    n += 1;
                }
                let line = core::slice::from_raw_parts(buffer.as_ptr() as *const u8, n);
                let line = if !line.is_empty() && line[line.len() - 1] == b'\n' {
                    &line[..line.len() - 1]
                } else {
                    line
                };
                runCommand(&line.to_vec());
            }
        }

        0
    }
}
