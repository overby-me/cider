#ifndef __CGBase_H__
#define __CGBase_H__

#include <float.h>

// Moved over from our CoreFoundation

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

#endif
