# Vec: 3D float vectors.
#
# Everything the tracer does with geometry goes through this module. V3 is
# `Data`, so a vector may be marked `+` and used more than once; that matters a
# lot below, where one ray direction feeds every object in the scene.
#
# Bend is affine: a plain binding is consumed by its first use. Several defs
# here exist only to copy a field with `+` before using it twice, which is why
# there is both a `V3.len` and a `V3.len.copy`.

import Base

type V3 is Data:
  V3{x: F32, y: F32, z: F32}

def V3.add(a: V3, b: V3) -> V3:
  match a b:
    case V3{ax, ay, az} V3{bx, by, bz}:
      V3{(ax + bx : F32), (ay + by : F32), (az + bz : F32)}

def V3.sub(a: V3, b: V3) -> V3:
  match a b:
    case V3{ax, ay, az} V3{bx, by, bz}:
      V3{(ax - bx : F32), (ay - by : F32), (az - bz : F32)}

# Component-wise product: used to tint a light's color by an albedo.
def V3.mul(a: V3, b: V3) -> V3:
  match a b:
    case V3{ax, ay, az} V3{bx, by, bz}:
      V3{(ax * bx : F32), (ay * by : F32), (az * bz : F32)}

def V3.scale(a: V3, +k: F32) -> V3:
  match a:
    case V3{ax, ay, az}:
      V3{(ax * k : F32), (ay * k : F32), (az * k : F32)}

def V3.neg(a: V3) -> V3:
  match a:
    case V3{ax, ay, az}:
      V3{F32.neg(ax), F32.neg(ay), F32.neg(az)}

def V3.splat(+k: F32) -> V3:
  V3{k, k, k}

def V3.dot(a: V3, b: V3) -> F32:
  match a b:
    case V3{ax, ay, az} V3{bx, by, bz}:
      (ax * bx + ay * by + az * bz : F32)

def V3.cross(a: V3, b: V3) -> V3:
  match a b:
    case V3{ax, ay, az} V3{bx, by, bz}:
      +ax = ax
      +ay = ay
      +az = az
      +bx = bx
      +by = by
      +bz = bz
      V3{(ay * bz - az * by : F32), (az * bx - ax * bz : F32),
        (ax * by - ay * bx : F32)}

# `V3.dot(a, a)` would use `a` twice, so the squared length copies the fields.
def V3.dot2(a: V3) -> F32:
  match a:
    case V3{ax, ay, az}:
      +ax = ax
      +ay = ay
      +az = az
      (ax * ax + ay * ay + az * az : F32)

def V3.len(a: V3) -> F32:
  F32.sqrt(V3.dot2(a))

# A zero-length vector would divide by zero, so the denominator gets a floor.
def V3.norm(+a: V3) -> V3:
  +l = F32.max(V3.len(a), 0.000001)
  V3.scale(a, (1.0 / l : F32))

# The mirror law: d reflected about a unit normal n.
def V3.reflect(+d: V3, +n: V3) -> V3:
  +k = (2.0 * V3.dot(d, n) : F32)
  V3.sub(d, V3.scale(n, k))

def V3.lerp(a: V3, b: V3, +t: F32) -> V3:
  V3.add(V3.scale(a, (1.0 - t : F32)), V3.scale(b, t))
