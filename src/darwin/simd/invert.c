/*
 * The matrix inverses libsimd exports and this port never had.
 *
 * WHO ASKS: /usr/lib/swift/libswiftsimd.dylib binds ___invert_d2 and friends, EXPECTED IN
 * libSystem.B.dylib, so the definition has to live there and nowhere else; a two-level namespace
 * binding names the library it must come from. iTerm2 dies with signal 6 the moment a menu reaches
 * Swift code that inverts a matrix, which is a lazy bind abort and names nothing by itself.
 * Task #228.
 *
 * COLUMN MAJOR, as simd_struct declares: columns[c][r] is row r of column c, so a flat array in
 * that order is the OpenGL layout the 4x4 routine below is written for.
 *
 * A SINGULAR MATRIX IS NOT AN ERROR HERE. simd_inverse divides by the determinant and lets the
 * result be infinite or NaN, and a caller that checks does so on the result, so do not invent a
 * policy by returning zeroes.
 */

#include <simd/simd.h>

#define INVERT_2(T, M)                                                       \
	do {                                                                     \
		const T a = (M).columns[0][0], c = (M).columns[0][1];                \
		const T b = (M).columns[1][0], d = (M).columns[1][1];                \
		const T rdet = (T) 1 / (a * d - b * c);                              \
		(M).columns[0][0] =  d * rdet;                                       \
		(M).columns[0][1] = -c * rdet;                                       \
		(M).columns[1][0] = -b * rdet;                                       \
		(M).columns[1][1] =  a * rdet;                                       \
	} while (0)

#define INVERT_3(T, M)                                                       \
	do {                                                                     \
		const T a = (M).columns[0][0], d = (M).columns[0][1], g = (M).columns[0][2]; \
		const T b = (M).columns[1][0], e = (M).columns[1][1], h = (M).columns[1][2]; \
		const T c = (M).columns[2][0], f = (M).columns[2][1], i = (M).columns[2][2]; \
		const T A =  (e * i - f * h), B = -(d * i - f * g), C =  (d * h - e * g);    \
		const T rdet = (T) 1 / (a * A + b * B + c * C);                      \
		(M).columns[0][0] = A * rdet;                                        \
		(M).columns[1][0] = -(b * i - c * h) * rdet;                         \
		(M).columns[2][0] =  (b * f - c * e) * rdet;                         \
		(M).columns[0][1] = B * rdet;                                        \
		(M).columns[1][1] =  (a * i - c * g) * rdet;                         \
		(M).columns[2][1] = -(a * f - c * d) * rdet;                         \
		(M).columns[0][2] = C * rdet;                                        \
		(M).columns[1][2] = -(a * h - b * g) * rdet;                         \
		(M).columns[2][2] =  (a * e - b * d) * rdet;                         \
	} while (0)

/* The classic sixteen cofactor expansion over a column major flat array. */
#define INVERT_4(T, M)                                                       \
	do {                                                                     \
		T f[16], v[16], rdet;                                                \
		for (int col = 0; col < 4; col++)                                    \
			for (int row = 0; row < 4; row++)                                \
				f[col * 4 + row] = (M).columns[col][row];                    \
                                                                             \
		v[0]  =  f[5]*f[10]*f[15] - f[5]*f[11]*f[14] - f[9]*f[6]*f[15]       \
			  +  f[9]*f[7]*f[14] + f[13]*f[6]*f[11] - f[13]*f[7]*f[10];      \
		v[4]  = -f[4]*f[10]*f[15] + f[4]*f[11]*f[14] + f[8]*f[6]*f[15]       \
			  -  f[8]*f[7]*f[14] - f[12]*f[6]*f[11] + f[12]*f[7]*f[10];      \
		v[8]  =  f[4]*f[9]*f[15]  - f[4]*f[11]*f[13] - f[8]*f[5]*f[15]       \
			  +  f[8]*f[7]*f[13] + f[12]*f[5]*f[11] - f[12]*f[7]*f[9];       \
		v[12] = -f[4]*f[9]*f[14]  + f[4]*f[10]*f[13] + f[8]*f[5]*f[14]       \
			  -  f[8]*f[6]*f[13] - f[12]*f[5]*f[10] + f[12]*f[6]*f[9];       \
		v[1]  = -f[1]*f[10]*f[15] + f[1]*f[11]*f[14] + f[9]*f[2]*f[15]       \
			  -  f[9]*f[3]*f[14] - f[13]*f[2]*f[11] + f[13]*f[3]*f[10];      \
		v[5]  =  f[0]*f[10]*f[15] - f[0]*f[11]*f[14] - f[8]*f[2]*f[15]       \
			  +  f[8]*f[3]*f[14] + f[12]*f[2]*f[11] - f[12]*f[3]*f[10];      \
		v[9]  = -f[0]*f[9]*f[15]  + f[0]*f[11]*f[13] + f[8]*f[1]*f[15]       \
			  -  f[8]*f[3]*f[13] - f[12]*f[1]*f[11] + f[12]*f[3]*f[9];       \
		v[13] =  f[0]*f[9]*f[14]  - f[0]*f[10]*f[13] - f[8]*f[1]*f[14]       \
			  +  f[8]*f[2]*f[13] + f[12]*f[1]*f[10] - f[12]*f[2]*f[9];       \
		v[2]  =  f[1]*f[6]*f[15]  - f[1]*f[7]*f[14]  - f[5]*f[2]*f[15]       \
			  +  f[5]*f[3]*f[14] + f[13]*f[2]*f[7]  - f[13]*f[3]*f[6];       \
		v[6]  = -f[0]*f[6]*f[15]  + f[0]*f[7]*f[14]  + f[4]*f[2]*f[15]       \
			  -  f[4]*f[3]*f[14] - f[12]*f[2]*f[7]  + f[12]*f[3]*f[6];       \
		v[10] =  f[0]*f[5]*f[15]  - f[0]*f[7]*f[13]  - f[4]*f[1]*f[15]       \
			  +  f[4]*f[3]*f[13] + f[12]*f[1]*f[7]  - f[12]*f[3]*f[5];       \
		v[14] = -f[0]*f[5]*f[14]  + f[0]*f[6]*f[13]  + f[4]*f[1]*f[14]       \
			  -  f[4]*f[2]*f[13] - f[12]*f[1]*f[6]  + f[12]*f[2]*f[5];       \
		v[3]  = -f[1]*f[6]*f[11]  + f[1]*f[7]*f[10]  + f[5]*f[2]*f[11]       \
			  -  f[5]*f[3]*f[10] - f[9]*f[2]*f[7]   + f[9]*f[3]*f[6];        \
		v[7]  =  f[0]*f[6]*f[11]  - f[0]*f[7]*f[10]  - f[4]*f[2]*f[11]       \
			  +  f[4]*f[3]*f[10] + f[8]*f[2]*f[7]   - f[8]*f[3]*f[6];        \
		v[11] = -f[0]*f[5]*f[11]  + f[0]*f[7]*f[9]   + f[4]*f[1]*f[11]       \
			  -  f[4]*f[3]*f[9]  - f[8]*f[1]*f[7]   + f[8]*f[3]*f[5];        \
		v[15] =  f[0]*f[5]*f[10]  - f[0]*f[6]*f[9]   - f[4]*f[1]*f[10]       \
			  +  f[4]*f[2]*f[9]  + f[8]*f[1]*f[6]   - f[8]*f[2]*f[5];        \
                                                                             \
		rdet = (T) 1 / (f[0]*v[0] + f[1]*v[4] + f[2]*v[8] + f[3]*v[12]);     \
		for (int col = 0; col < 4; col++)                                    \
			for (int row = 0; row < 4; row++)                                \
				(M).columns[col][row] = v[col * 4 + row] * rdet;             \
	} while (0)

simd_float2x2 __invert_f2(simd_float2x2 m) { INVERT_2(float, m); return m; }
simd_float3x3 __invert_f3(simd_float3x3 m) { INVERT_3(float, m); return m; }
simd_float4x4 __invert_f4(simd_float4x4 m) { INVERT_4(float, m); return m; }

simd_double2x2 __invert_d2(simd_double2x2 m) { INVERT_2(double, m); return m; }
simd_double3x3 __invert_d3(simd_double3x3 m) { INVERT_3(double, m); return m; }
simd_double4x4 __invert_d4(simd_double4x4 m) { INVERT_4(double, m); return m; }
