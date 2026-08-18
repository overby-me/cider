/*
 * 4x4 MATRIX ARITHMETIC, AND NOTHING ELSE. Only the identity constant was here, so a layer that
 * asked for a scale got a link error rather than a matrix; this is the whole documented family,
 * which is pure arithmetic and owes nothing to a render server.
 *
 * The convention is Core Animation's: row vectors multiplied on the LEFT, so concatenating a onto b
 * means a then b, and the translation lives in the fourth ROW.
 */

#import <QuartzCore/CATransform3D.h>
#import <math.h>

const CATransform3D CATransform3DIdentity = {1, 0, 0, 0, 0, 1, 0, 0,
                                             0, 0, 1, 0, 0, 0, 0, 1};

bool CATransform3DIsIdentity(CATransform3D t) {
    return CATransform3DEqualToTransform(t, CATransform3DIdentity);
}

bool CATransform3DEqualToTransform(CATransform3D a, CATransform3D b) {
    return a.m11 == b.m11 && a.m12 == b.m12 && a.m13 == b.m13 && a.m14 == b.m14 &&
           a.m21 == b.m21 && a.m22 == b.m22 && a.m23 == b.m23 && a.m24 == b.m24 &&
           a.m31 == b.m31 && a.m32 == b.m32 && a.m33 == b.m33 && a.m34 == b.m34 &&
           a.m41 == b.m41 && a.m42 == b.m42 && a.m43 == b.m43 && a.m44 == b.m44;
}

CATransform3D CATransform3DMakeTranslation(CGFloat tx, CGFloat ty, CGFloat tz) {
    CATransform3D t = CATransform3DIdentity;

    t.m41 = tx;
    t.m42 = ty;
    t.m43 = tz;

    return t;
}

CATransform3D CATransform3DMakeScale(CGFloat sx, CGFloat sy, CGFloat sz) {
    CATransform3D t = CATransform3DIdentity;

    t.m11 = sx;
    t.m22 = sy;
    t.m33 = sz;

    return t;
}

CATransform3D CATransform3DMakeRotation(CGFloat angle, CGFloat x, CGFloat y, CGFloat z) {
    CGFloat length = sqrt(x * x + y * y + z * z);

    // A zero axis names no rotation, and normalising it would divide by zero.
    if (length == 0.0) {
        return CATransform3DIdentity;
    }

    x /= length;
    y /= length;
    z /= length;

    CGFloat c = cos(angle);
    CGFloat s = sin(angle);
    CGFloat k = 1.0 - c;
    CATransform3D t = CATransform3DIdentity;

    t.m11 = x * x * k + c;
    t.m12 = x * y * k + z * s;
    t.m13 = x * z * k - y * s;

    t.m21 = x * y * k - z * s;
    t.m22 = y * y * k + c;
    t.m23 = y * z * k + x * s;

    t.m31 = x * z * k + y * s;
    t.m32 = y * z * k - x * s;
    t.m33 = z * z * k + c;

    return t;
}

CATransform3D CATransform3DConcat(CATransform3D a, CATransform3D b) {
    const CGFloat *l = &a.m11;
    const CGFloat *r = &b.m11;
    CATransform3D result;
    CGFloat *o = &result.m11;

    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            o[row * 4 + col] = l[row * 4 + 0] * r[0 * 4 + col] +
                               l[row * 4 + 1] * r[1 * 4 + col] +
                               l[row * 4 + 2] * r[2 * 4 + col] +
                               l[row * 4 + 3] * r[3 * 4 + col];
        }
    }

    return result;
}

CATransform3D CATransform3DTranslate(CATransform3D t, CGFloat tx, CGFloat ty, CGFloat tz) {
    return CATransform3DConcat(CATransform3DMakeTranslation(tx, ty, tz), t);
}

CATransform3D CATransform3DScale(CATransform3D t, CGFloat sx, CGFloat sy, CGFloat sz) {
    return CATransform3DConcat(CATransform3DMakeScale(sx, sy, sz), t);
}

CATransform3D CATransform3DRotate(CATransform3D t, CGFloat angle, CGFloat x, CGFloat y, CGFloat z) {
    return CATransform3DConcat(CATransform3DMakeRotation(angle, x, y, z), t);
}

/*
 * GAUSS-JORDAN WITH PARTIAL PIVOTING. Apple returns the original matrix unchanged when it cannot be
 * inverted, so a singular matrix is not an error here either.
 */
CATransform3D CATransform3DInvert(CATransform3D t) {
    CGFloat m[4][8];
    const CGFloat *src = &t.m11;

    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            m[row][col] = src[row * 4 + col];
            m[row][4 + col] = (row == col) ? 1.0 : 0.0;
        }
    }

    for (int col = 0; col < 4; col++) {
        int pivot = col;
        for (int row = col + 1; row < 4; row++) {
            if (fabs(m[row][col]) > fabs(m[pivot][col])) {
                pivot = row;
            }
        }

        if (fabs(m[pivot][col]) < 1e-12) {
            return t; // singular
        }

        if (pivot != col) {
            for (int k = 0; k < 8; k++) {
                CGFloat swap = m[col][k];
                m[col][k] = m[pivot][k];
                m[pivot][k] = swap;
            }
        }

        CGFloat d = m[col][col];
        for (int k = 0; k < 8; k++) {
            m[col][k] /= d;
        }

        for (int row = 0; row < 4; row++) {
            if (row == col) {
                continue;
            }
            CGFloat f = m[row][col];
            if (f == 0.0) {
                continue;
            }
            for (int k = 0; k < 8; k++) {
                m[row][k] -= f * m[col][k];
            }
        }
    }

    CATransform3D result;
    CGFloat *out = &result.m11;
    for (int row = 0; row < 4; row++) {
        for (int col = 0; col < 4; col++) {
            out[row * 4 + col] = m[row][4 + col];
        }
    }

    return result;
}

CATransform3D CATransform3DMakeAffineTransform(CGAffineTransform m) {
    CATransform3D t = CATransform3DIdentity;

    t.m11 = m.a;
    t.m12 = m.b;
    t.m21 = m.c;
    t.m22 = m.d;
    t.m41 = m.tx;
    t.m42 = m.ty;

    return t;
}

bool CATransform3DIsAffine(CATransform3D t) {
    return t.m13 == 0.0 && t.m14 == 0.0 &&
           t.m23 == 0.0 && t.m24 == 0.0 &&
           t.m31 == 0.0 && t.m32 == 0.0 && t.m33 == 1.0 && t.m34 == 0.0 &&
           t.m43 == 0.0 && t.m44 == 1.0;
}

CGAffineTransform CATransform3DGetAffineTransform(CATransform3D t) {
    // Apple returns the affine part whether or not the matrix is affine, so no check here either.
    return CGAffineTransformMake(t.m11, t.m12, t.m21, t.m22, t.m41, t.m42);
}
