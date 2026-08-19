#ifndef __CGBase_H__
#define __CGBase_H__

#include <float.h>

// Moved over from our CoreFoundation

/* GUARDED, because CoreFoundation defines these too, exactly as Apple does. Whichever header the
 * translation unit sees first wins and the other stands down; without the guard a file that
 * includes both gets a duplicate typedef. */
#if !defined(CGFLOAT_DEFINED)
#ifdef __LP64__
typedef double CGFloat;
#define CGFLOAT_MIN DBL_MIN
#define CGFLOAT_MAX DBL_MAX
#define CGFLOAT_SCAN "%lg"
#define CGFLOAT_IS_DOUBLE 1
#else
typedef float CGFloat;
#define CGFLOAT_MIN FLT_MIN
#define CGFLOAT_MAX FLT_MAX
#define CGFLOAT_SCAN "%g"
#define CGFLOAT_IS_DOUBLE 0
#endif

#define CGFLOAT_DEFINED 1
#endif /* CGFLOAT_DEFINED */

#endif
