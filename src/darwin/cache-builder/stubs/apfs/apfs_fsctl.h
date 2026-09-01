// cider #11 lever A: empty stub for <apfs/apfs_fsctl.h>.
// dyld3/shared-cache/SharedCacheBuilder.cpp includes this Apple APFS control header, which cider's guest
// SDK does not ship. It is only an include there (no apfs_fsctl symbols are referenced), so an empty header
// satisfies the include. If a real apfs symbol turns out to be needed, add the declaration here.
#ifndef CIDER_STUB_APFS_FSCTL_H
#define CIDER_STUB_APFS_FSCTL_H
#endif
