# Render: the camera, the colour packing, and the quadtree split.
#
# Two things here are deliberately integer-valued rather than float:
#
#   * the camera's yaw and pitch, held in tenths of a degree, so the pitch
#     clamp is an integer comparison a law can reason about (Bend's F32 ops are
#     opaque primitives, so nothing can be proven about them);
#   * the final colour clamp, which caps a U32 channel at 255.
#
# Both compile to single native instructions, so the proofs cost nothing.

import Base
import ./vec.bend as V
import ./scene.bend as S

# -- Resolution ---------------------------------------------------------------

# An Image is a quadtree over a 2^k square, so the natural frame sizes are
# powers of two. Depth 9 is 512x512; depth 7 is 128x128, which the window
# scales up by leaving each Pix covering a 4x4 block.
def Render.FULL_D() -> Nat:
  9n

def Render.DRAG_D() -> Nat:
  7n

def Render.WIDTH() -> U32:
  512

def Render.HEIGHT() -> U32:
  512

# -- Colour -------------------------------------------------------------------

# The float clamp below already keeps a channel inside [0,1], but nothing can
# be proven about F32. `Color.cap` redoes the bound over U32, where `U32.cmp`
# is a native comparison and the result is something `Laws.channel_bounded`
# can state. The Cmp goes through a parameter because Bend only matches
# parameters, and that is also what lets the proof case-split on it.
def Color.MAX() -> U32:
  255

def Color.cap.go(c: Cmp, v: U32) -> U32:
  match c:
    case LT{}:
      v
    case EQ{}:
      v
    case GT{}:
      Color.MAX()

def Color.cap(+v: U32) -> U32:
  Color.cap.go(U32.cmp(v, Color.MAX()), v)

# Gamma 2.0, then to a byte.
def Color.byte(v: F32) -> U32:
  Color.cap(F32.to_u32(
    (F32.sqrt(F32.clamp(v, 0.0, 1.0)) * 255.0 + 0.5 : F32)))

# The window reads a Pix as 0xRRGGBB.
def Color.pack(c: V.V3) -> U32:
  match c:
    case V.V3{r, g, b}:
      (Color.byte(r) * 65536 + Color.byte(g) * 256 + Color.byte(b) : U32)

# -- Camera -------------------------------------------------------------------

# yaw and pitch are tenths of a degree. pitch runs 0..1780 and decodes to
# -89.0..+89.0, so the camera can never reach the poles and flip over.
# dist is tenths of a world unit.
type Cam is Data:
  Cam{yaw: U32, pitch: U32, dist: U32}

def Cam.PITCH_MAX() -> U32:
  1780

def Cam.YAW_WRAP() -> U32:
  3600

def Cam.DIST_MIN() -> U32:
  25

def Cam.DIST_MAX() -> U32:
  260

def Cam.TARGET() -> V.V3:
  V.V3{0.0, 0.95, 0.0}

# tan(fov/2) for a 60 degree vertical field of view.
def Cam.TANHALF() -> F32:
  0.5774

def Cam.pitch_ok(+v: U32) -> Bool:
  U32.is_le(v, Cam.PITCH_MAX())

def Cam.pitch_clamp.go(c: Cmp, v: U32) -> U32:
  match c:
    case LT{}:
      v
    case EQ{}:
      v
    case GT{}:
      Cam.PITCH_MAX()

def Cam.pitch_clamp(+v: U32) -> U32:
  Cam.pitch_clamp.go(U32.cmp(v, Cam.PITCH_MAX()), v)

# A drag down past the bottom would underflow U32 and wrap to a huge value,
# which the clamp would then read as "too high". So the subtraction saturates
# at zero first, and only the top end needs clamping.
def Cam.step.sub(under: Bool, v: U32, dn: U32) -> U32:
  match under:
    case True{}:
      0
    case False{}:
      (v - dn : U32)

def Cam.step.raw(up: Bool, +v: U32, +dn: U32) -> U32:
  match up:
    case True{}:
      (v + dn : U32)
    case False{}:
      Cam.step.sub(U32.is_lt(v, dn), v, dn)

# The only way the app changes pitch. `Laws.pitch_in_range` proves the result
# is always in 0..1780, whatever the drag was.
def Cam.pitch_step(+v: U32, +dn: U32, up: Bool) -> U32:
  Cam.pitch_clamp(Cam.step.raw(up, v, dn))

# Yaw wraps instead of clamping.
def Cam.yaw_step(+v: U32, +dn: U32, up: Bool) -> U32:
  (Cam.step.raw(up, v, dn) % Cam.YAW_WRAP() : U32)

def Cam.dist_clamp.go(lo: Bool, hi: Bool, v: U32) -> U32:
  match lo hi:
    case True{} _:
      Cam.DIST_MIN()
    case False{} True{}:
      Cam.DIST_MAX()
    case False{} False{}:
      v

def Cam.dist_clamp(+v: U32) -> U32:
  Cam.dist_clamp.go(U32.is_lt(v, Cam.DIST_MIN()),
    U32.is_gt(v, Cam.DIST_MAX()), v)

def Cam.dist_step(+v: U32, +dn: U32, up: Bool) -> U32:
  Cam.dist_clamp(Cam.step.raw(up, v, dn))

def Cam.DEG() -> F32:
  0.0174532925

def Cam.yaw_rad(v: U32) -> F32:
  (U32.to_f32(v) * 0.1 * Cam.DEG() : F32)

def Cam.pitch_rad(v: U32) -> F32:
  ((U32.to_f32(v) * 0.1 - 89.0) * Cam.DEG() : F32)

def Cam.dist_f(v: U32) -> F32:
  (U32.to_f32(v) * 0.1 : F32)

def Cam.eye(c: Cam) -> V.V3:
  match c:
    case Cam{yaw, pitch, dist}:
      +yr = Cam.yaw_rad(yaw)
      +pr = Cam.pitch_rad(pitch)
      +d = Cam.dist_f(dist)
      +cp = F32.cos(pr)
      V.V3.add(Cam.TARGET(), V.V3{(d * cp * F32.sin(yr) : F32),
        (d * F32.sin(pr) : F32), (d * cp * F32.cos(yr) : F32)})

# -- Rays ---------------------------------------------------------------------

# The camera frame, built once per frame and carried down the quadtree so the
# per-pixel work is two multiply-adds and a normalize rather than four trig
# calls.
type Basis is Data:
  Basis{eye: V.V3, fwd: V.V3, rgt: V.V3, upv: V.V3, inv: F32}

def Basis.of(c: Cam, size: F32) -> Basis:
  +eye = Cam.eye(c)
  +fwd = V.V3.norm(V.V3.sub(Cam.TARGET(), eye))
  +rgt = V.V3.norm(V.V3.cross(fwd, V.V3{0.0, 1.0, 0.0}))
  Basis{eye, fwd, rgt, V.V3.cross(rgt, fwd),
    (2.0 * Cam.TANHALF() / size : F32)}

def Render.pixel(bs: Basis, x: U32, y: U32) -> U32:
  match bs:
    case Basis{eye, fwd, rgt, upv, +inv}:
      # Pixel centres, mapped to [-tanhalf, +tanhalf]; y is flipped because
      # the window's rows run downwards.
      +u = ((U32.to_f32(x) + 0.5) * inv - Cam.TANHALF() : F32)
      +v = (Cam.TANHALF() - (U32.to_f32(y) + 0.5) * inv : F32)
      rd = V.V3.norm(V.V3.add(fwd,
        V.V3.add(V.V3.scale(rgt, u), V.V3.scale(upv, v))))
      Color.pack(S.Trace.start(eye, rd))

# -- The quadtree -------------------------------------------------------------

# The frame is split into four equal quadrants, all the way down to one pixel.
# The four calls are a parallel call, and they are balanced by construction:
# every quadrant is the same size and every leaf costs the same ray. That is
# what Bend's fork-join scheduler needs to spread the frame over every core or
# GPU lane.
def Render.tile(+d: Nat, +step: U32, +x: U32, +y: U32, +bs: Basis) -> Image:
  match d:
    case 0n:
      Pix{Render.pixel(bs, x, y)}
    case 1n+p:
      +h = U32.shr(step)
      tl tr bl br = Render.tile(p, h, x, y, bs)
        Render.tile(p, h, (x + h : U32), y, bs)
        Render.tile(p, h, x, (y + h : U32), bs)
        Render.tile(p, h, (x + h : U32), (y + h : U32), bs)
      Qua{tl, tr, bl, br}

def Render.size(+d: Nat) -> U32:
  U32.shln(1, d)

# `!` hands the whole tree to the GPU; every parallel call inside it goes
# there too.
def Render.at(+d: Nat, c: Cam) -> Image:
  +n = Render.size(d)
  Render.tile!(d, n, 0, 0, Basis.of(c, U32.to_f32(n)))

def Render.frame.go(low: Bool, c: Cam) -> Image:
  match low:
    case True{}:
      Render.at(Render.DRAG_D(), c)
    case False{}:
      Render.at(Render.FULL_D(), c)

# While the mouse is down the frame is rendered at 128x128 and the window
# scales it up; on release it is redrawn at 512x512.
def Render.frame(low: Bool, c: Cam) -> Image:
  Render.frame.go(low, c)

# -- Frame shape --------------------------------------------------------------

# Counts the pixels of a quadtree that is exactly `d` levels deep. A tree that
# stops early, or that keeps splitting past `d`, is not a `d`-level frame and
# contributes nothing. `Laws.frame_pixels` uses this to say that a rendered
# frame has exactly 2^d * 2^d pixels.
def Img.count(+d: Nat, img: Image) -> Nat:
  match d:
    case 0n:
      match img:
        case Pix{c}:
          1n
        case Qua{tl, tr, bl, br}:
          0n
    case 1n+p:
      match img:
        case Pix{c}:
          0n
        case Qua{tl, tr, bl, br}:
          Nat.add(Img.count(p, tl), Nat.add(Img.count(p, tr),
            Nat.add(Img.count(p, bl), Img.count(p, br))))

# Sums every pixel, in parallel, mirroring the render split. The benchmark
# uses it to make sure the whole frame is really computed.
def Img.sum(+d: Nat, img: Image) -> U32:
  match d:
    case 0n:
      match img:
        case Pix{c}:
          c
        case Qua{tl, tr, bl, br}:
          0
    case 1n+p:
      match img:
        case Pix{c}:
          c
        case Qua{tl, tr, bl, br}:
          a b c e = Img.sum(p, tl) Img.sum(p, tr) Img.sum(p, bl)
            Img.sum(p, br)
          (a + b + c + e : U32)
