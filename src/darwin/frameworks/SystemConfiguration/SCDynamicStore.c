/*
 This file is part of Darling.

 Copyright (C) 2026 Darling Developers

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

// The rustls crate resolves these two, so anything Rust built or run in the guest needs them.
// configd's own SCDynamicStore.h DECLARES both (SCDynamicStoreCreateWithOptions and the
// kSCDynamicStoreUseSessionKeys option key) but nothing in the tree DEFINED either, so a
// consumer linked against an undefined symbol. Upstream 3d9752422d5e added the same pair.
//
// stdio.h explicitly: upstream's copy includes only SCDynamicStore.h and relies on printf
// arriving transitively, which is not something to depend on here.

#include <SystemConfiguration/SCDynamicStore.h>
#include <stdio.h>

const CFStringRef kSCDynamicStoreUseSessionKeys = CFSTR("UseSessionKeys");

SCDynamicStoreRef __nullable
SCDynamicStoreCreateWithOptions(CFAllocatorRef __nullable allocator, CFStringRef name,
                                CFDictionaryRef __nullable storeOptions,
                                SCDynamicStoreCallBack __nullable callout,
                                SCDynamicStoreContext* __nullable context)
{
	printf("STUB %s\n", __PRETTY_FUNCTION__);

	return NULL;
};
