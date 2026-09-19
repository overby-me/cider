#include <CoreFoundation/CoreFoundation.h>

// unsure
const double CoreServicesVersionNumber = 1239;
const char* const CoreServicesVersionString = "@(#)PROGRAM:CoreServices  PROJECT:CoreServices-1239\n";

// this probably shouldn't be here
const CFStringRef kFSOperationBytesCompleteKey = CFSTR("kFSOperationBytesDoneKey");
const CFStringRef kFSOperationTotalBytesKey = CFSTR("kFSOperationTotalBytesKey");

/*
 * ICON SERVICES, IN CoreServices BECAUSE THAT IS THE LIBRARY THE CALLER NAMES.
 *
 * Mach-O is two-level namespace: an undefined symbol records which dylib it must come from, and
 * defining it anywhere else does not satisfy it. llvm-nm -m on the caller is what settles it:
 *   (undefined) external _GetIconRef (from CoreServices)
 *   (undefined) external _ReleaseIconRef (from CoreServices)
 * I first put GetIconRef in HIServices, which exported it correctly and changed nothing at all,
 * because libqcocoa was never going to look there. Task #235, and the same shape as #226.
 *
 * There is no icon database here to answer from. fnfErr with a NULL out parameter is what a caller
 * already handles, since Icon Services genuinely answers not-found for an unregistered icon and Qt
 * falls back to drawing its own. The out parameter is cleared BEFORE the error return so a caller
 * that checks the pointer rather than the status is not handed a stale stack value.
 */
typedef struct OpaqueIconRef *IconRef;

OSStatus GetIconRef(SInt16 vRefNum, OSType creator, OSType iconType, IconRef *theIconRef)
{
    if (theIconRef != NULL)
        *theIconRef = NULL;
    return -43 /* fnfErr */;
}

/* Releasing an icon nobody handed out is a no-op, not an error: the caller is balancing a failed
 * GetIconRef and must not be told its cleanup went wrong. */
OSStatus ReleaseIconRef(IconRef theIconRef)
{
    return noErr;
}
