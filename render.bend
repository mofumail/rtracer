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

# An Image is a quadtree over a 2^k square, and the window walks it with
# k = the smallest power of two covering max(w, h). For a 1920x1080 window
# that is k = 11, so the frame is a 2048x2048 tree and the window shows its
# top-left corner. The rays are aimed at the *visible* rectangle (see
# `Basis.of`), not at the square, so the extra columns and rows are simply
# traced and never looked at.
#
# The waste is unavoidable rather than sloppy: pruning the off-screen
# quadrants would save about half the rays but unbalance the split, and Bend
# hands every task to a core once and never moves it, so the idle lanes would
# give the saving straight back.
def Render.FULL_D() -> Nat:
  11n

def Render.WIDTH() -> U32:
  1920

def Render.HEIGHT() -> U32:
  1080

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
# dist is hundredths of a world unit.
type Cam is Data:
  Cam{yaw: U32, pitch: U32, dist: U32}

def Cam.PITCH_MAX() -> U32:
  1780

def Cam.YAW_WRAP() -> U32:
  3600

# Distance is held in hundredths of a world unit rather than tenths: a mouse
# drag moves it a few units per hundred pixels, and tenths were too coarse a
# step to express that without jumping.
def Cam.DIST_MIN() -> U32:
  250

def Cam.DIST_MAX() -> U32:
  2600

def Cam.TARGET() -> V.V3:
  V.V3{0.0, 0.95, 0.0}

# tan(vfov/2) for a 40 degree *vertical* field of view. On a 16:9 frame the
# horizontal one works out at about 66 degrees; fixing the vertical angle and
# deriving the horizontal is what keeps a widescreen frame from turning into
# a fisheye.
def Cam.TANHALF() -> F32:
  0.36397

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

# Yaw wraps instead of clamping, so it needs its own stepper: `Cam.step.raw`
# saturates at zero on the way down, which is right for pitch and wrong here.
# Reusing it meant dragging left walked the yaw down to 0 and stuck there,
# while dragging right wrapped forever.
#
# Both operands are reduced modulo a full turn first, so `v + WRAP - d` cannot
# underflow a U32.
def Cam.yaw_step.go(up: Bool, +v: U32, +d: U32) -> U32:
  match up:
    case True{}:
      ((v + d) % Cam.YAW_WRAP() : U32)
    case False{}:
      ((v + Cam.YAW_WRAP() - d) % Cam.YAW_WRAP() : U32)

def Cam.yaw_step(+v: U32, +dn: U32, up: Bool) -> U32:
  Cam.yaw_step.go(up, (v % Cam.YAW_WRAP() : U32),
    (dn % Cam.YAW_WRAP() : U32))

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
  (U32.to_f32(v) * 0.01 : F32)

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
#
# hx/hy are the half-extents of the image plane and ix/iy the per-pixel step.
# They are derived from the *visible* rectangle, so the picture stays centred
# and correctly proportioned even though the tree it lives in is square.
type Basis is Data:
  Basis{eye: V.V3, fwd: V.V3, rgt: V.V3, upv: V.V3, hx: F32, hy: F32,
    ix: F32, iy: F32}

def Basis.of(c: Cam, +vw: F32, +vh: F32) -> Basis:
  +eye = Cam.eye(c)
  +fwd = V.V3.norm(V.V3.sub(Cam.TARGET(), eye))
  +rgt = V.V3.norm(V.V3.cross(fwd, V.V3{0.0, 1.0, 0.0}))
  # Vertical field of view is fixed; the horizontal one follows the aspect.
  +hy = Cam.TANHALF()
  +hx = (hy * vw / vh : F32)
  Basis{eye, fwd, rgt, V.V3.cross(rgt, fwd), hx, hy,
    (2.0 * hx / vw : F32), (2.0 * hy / vh : F32)}

# The direction of the primary ray through a pixel. Shared with the spawner
# in main.bend, so a shift-click aims at exactly the pixel under the cursor.
def Render.ray(bs: Basis, x: U32, y: U32) -> V.V3:
  match bs:
    case Basis{eye, fwd, rgt, upv, hx, hy, ix, iy}:
      # Pixel centres on the image plane; y is flipped because the window's
      # rows run downwards.
      +u = ((U32.to_f32(x) + 0.5) * ix - hx : F32)
      +v = (hy - (U32.to_f32(y) + 0.5) * iy : F32)
      V.V3.norm(V.V3.add(fwd,
        V.V3.add(V.V3.scale(rgt, u), V.V3.scale(upv, v))))

def Basis.eye(bs: Basis) -> V.V3:
  match bs:
    case Basis{eye, fwd, rgt, upv, hx, hy, ix, iy}:
      eye

# Destructures the Basis once rather than taking it `+` and calling
# `Basis.eye` and `Render.ray` on it. Those two read well, but using the
# record twice here duplicates it at every one of the frame's millions of
# leaves, which measured 51 ms/frame against 22 ms.
def Render.pixel(bs: Basis, balls: S.Cloud, x: U32, y: U32) -> U32:
  match bs:
    case Basis{eye, fwd, rgt, upv, hx, hy, ix, iy}:
      +u = ((U32.to_f32(x) + 0.5) * ix - hx : F32)
      +v = (hy - (U32.to_f32(y) + 0.5) * iy : F32)
      rd = V.V3.norm(V.V3.add(fwd,
        V.V3.add(V.V3.scale(rgt, u), V.V3.scale(upv, v))))
      Color.pack(S.Trace.start(balls, eye, rd))

# -- The quadtree -------------------------------------------------------------

# The frame is split into four equal quadrants, all the way down to one pixel.
# The four calls are a parallel call, and they are balanced by construction:
# every quadrant is the same size and every leaf costs the same ray. That is
# what Bend's fork-join scheduler needs to spread the frame over every core or
# GPU lane.
def Render.tile(+d: Nat, +step: U32, +x: U32, +y: U32, +bs: Basis,
  +balls: S.Cloud) -> Image:
  match d:
    case 0n:
      Pix{Render.pixel(bs, balls, x, y)}
    case 1n+p:
      +h = U32.shr(step)
      tl tr bl br = Render.tile(p, h, x, y, bs, balls)
        Render.tile(p, h, (x + h : U32), y, bs, balls)
        Render.tile(p, h, x, (y + h : U32), bs, balls)
        Render.tile(p, h, (x + h : U32), (y + h : U32), bs, balls)
      Qua{tl, tr, bl, br}

def Render.size(+d: Nat) -> U32:
  U32.shln(1, d)

# `!` hands the whole tree to the GPU; every parallel call inside it goes
# there too.
#
# The GPU is the right lane here even though the CPU traces rays faster: the
# window's own blit walks the tree once per screen pixel, and that walk is a
# serial loop on the CPU and a CUDA kernel on the GPU. Rendering on the CPU
# with the GPU enabled is worse than either, because the corpus then lives in
# managed memory and every CPU thread pays for it.
def Render.at(+d: Nat, c: Cam, +balls: S.Cloud) -> Image:
  Render.tile!(d, Render.size(d), 0, 0,
    Basis.of(c, U32.to_f32(Render.WIDTH()), U32.to_f32(Render.HEIGHT())),
    balls)

# There is only one resolution. An earlier version dropped to a shallower
# tree while the mouse was down; at depth 11 the frame holds ~40 fps, so the
# quality never has to drop.
def Render.frame(c: Cam, +balls: S.Cloud) -> Image:
  Render.at(Render.FULL_D(), c, balls)

# The camera frame for the live window, used by the spawner to turn a clicked
# pixel back into a world-space ray.
def Render.basis(c: Cam) -> Basis:
  Basis.of(c, U32.to_f32(Render.WIDTH()), U32.to_f32(Render.HEIGHT()))

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
