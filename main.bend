# The interactive viewer: an App whose view renders a frame and whose tick
# folds the window's events into the camera, spawns balls, and advances the
# physics.
#
# Every frame is traced fresh. An earlier version cached the rendered Image in
# the state and only re-traced when an event moved the camera, which looked
# like a clear win -- until it was measured. `view` has to return the state
# *and* the image, so a cached frame has to be used twice, and marking a
# freshly computed Image `+` turns out to cost far more than tracing it again:
# frames during a drag took 206 ms against 22 ms without the cache. Caching
# was making the interactive case 9x slower than not caching at all.
#
# Zoom is on the right mouse button rather than the wheel. Bend 2.0.5 cannot
# see the wheel at all: X11 reports it as buttons 4 and 5, and Bend's event
# pump filters to `b >= 1 && b <= 3` before the events ever reach a program.
# See NOTES-BEND.md.

import Base
import ./vec.bend as V
import ./scene.bend as S
import ./render.bend as R
import ./phys.bend as P

# Mouse pixels to tenths of a degree: a 1000-pixel drag sweeps about 200
# degrees.
def Ui.GAIN() -> U32:
  2

# Right-drag pixels to hundredths of a world unit.
def Ui.DOLLY() -> U32:
  4

# One arrow-key press, in hundredths of a world unit.
def Ui.ZOOM() -> U32:
  60

# How far above the clicked surface a new ball appears, so it visibly falls.
def Ui.DROP() -> F32:
  1.6

def Ui.KEY_ESC() -> U32:
  27

def Ui.KEY_UP() -> U32:
  63232

def Ui.KEY_DOWN() -> U32:
  63233

def Ui.KEY_SHIFT_L() -> U32:
  65592

def Ui.KEY_SHIFT_R() -> U32:
  65596

# -- State --------------------------------------------------------------------

# Which button is currently held, if any.
type Drag is Data:
  DNone{}
  DOrbit{}
  DZoom{}

# Pointer state, kept together so the event handlers stay readable: Bend has
# to destructure a record to read one field, so a flat eight-field state
# means every handler takes eight parameters.
type Ptr is Data:
  Ptr{drag: Drag, x: U32, y: U32, shift: Bool}

type St is Data:
  St{cam: R.Cam, ptr: Ptr, balls: S.Blobs, seed: U32, live: Bool}

def St.init() -> St:
  St{R.Cam{450, 1005, 780}, Ptr{DNone{}, 0, 0, False{}}, S.BNil{}, 12345,
    True{}}

def Drag.of.go(left: Bool, right: Bool) -> Drag:
  match left right:
    case True{} _:
      DOrbit{}
    case False{} True{}:
      DZoom{}
    case False{} False{}:
      DNone{}

# Left button orbits, right button zooms; middle is ignored.
def Drag.of(+button: U32) -> Drag:
  Drag.of.go(U32.is_eq(button, 0), U32.is_eq(button, 1))

# -- Random -------------------------------------------------------------------

# A plain linear congruential generator. The seed lives in the state, so the
# whole app stays pure and a given sequence of clicks is reproducible.
def Rng.next(+s: U32) -> U32:
  (s * 1664525 + 1013904223 : U32)

# The top bits are the well-behaved ones in an LCG, so shift before masking.
def Rng.unit(+s: U32) -> F32:
  (U32.to_f32(U32.and(U32.shrn(s, 13n), 4095)) * 0.000244140625 : F32)

def Rng.span(+s: U32, +lo: F32, +hi: F32) -> F32:
  (lo + (hi - lo) * Rng.unit(s) : F32)

# -- Spawning -----------------------------------------------------------------

# A ray that hits nothing still has to put the ball somewhere sensible.
def Spawn.sky(p: V.V3) -> V.V3:
  match p:
    case V.V3{x, y, z}:
      V.V3{x, 6.0, z}

def Spawn.point(c: S.Cand, +ro: V.V3, +rd: V.V3) -> V.V3:
  match c:
    case S.Void{}:
      Spawn.sky(V.V3.add(ro, V.V3.scale(rd, 16.0)))
    case S.Cand{+t, ctr, alb, refl, flat}:
      V.V3.add(V.V3.add(ro, V.V3.scale(rd, t)), V.V3{0.0, Ui.DROP(), 0.0})

# Aims at the pixel under the cursor, finds what is there, and drops the new
# ball from a little way above it.
#
# It calls `Scene.find.cold`, not `Scene.find`. They have the same body, but
# pointing this one cold call site at the renderer's copy stopped the compiler
# inlining it per pixel and doubled every frame's cost.
def Spawn.where(cam: R.Cam, balls: S.Blobs, x: U32, y: U32) -> V.V3:
  +bs = R.Render.basis(cam)
  +ro = R.Basis.eye(bs)
  +rd = R.Render.ray(bs, x, y)
  Spawn.point(S.Scene.find.cold(P.Phys.cloud(balls), ro, rd), ro, rd)

# Random radius, colour and a little random gloss.
def Spawn.ball(+seed: U32, at: V.V3) -> S.Ball:
  +s1 = Rng.next(seed)
  +s2 = Rng.next(s1)
  +s3 = Rng.next(s2)
  +s4 = Rng.next(s3)
  +s5 = Rng.next(s4)
  S.Ball{seed, at, V.V3{0.0, 0.0, 0.0}, Rng.span(s1, 0.22, 0.62),
    V.V3{Rng.span(s2, 0.18, 0.95), Rng.span(s3, 0.18, 0.95),
      Rng.span(s4, 0.18, 0.95)},
    Rng.span(s5, 0.0, 0.45)}

# The seed doubles as the ball's id, so ids never repeat and a ball can always
# recognise itself when colliding against the list.
def Spawn.add(s: St, x: U32, y: U32) -> St:
  match s:
    case St{+cam, ptr, +balls, +seed, live}:
      St{cam, ptr,
        S.BCons{Spawn.ball(seed, Spawn.where(cam, balls, x, y)),
          P.Phys.take(P.Phys.MAX(), balls)},
        Rng.next(seed), live}

# -- Input --------------------------------------------------------------------

def Delta.go(gt: Bool, a: U32, b: U32) -> U32:
  match gt:
    case True{}:
      (a - b : U32)
    case False{}:
      (b - a : U32)

# |a - b| without signed arithmetic.
def Delta(+a: U32, +b: U32) -> U32:
  Delta.go(U32.is_gt(a, b), a, b)

def St.dolly(c: R.Cam, +dn: U32, up: Bool) -> R.Cam:
  match c:
    case R.Cam{yaw, pitch, dist}:
      R.Cam{yaw, pitch, R.Cam.dist_step(dist, dn, up)}

# A drag turns the camera: horizontal motion wraps the yaw, vertical motion
# moves the pitch, which `Cam.pitch_step` keeps inside its legal range.
def St.turn(c: R.Cam, +x: U32, +y: U32, +mx: U32, +my: U32) -> R.Cam:
  match c:
    case R.Cam{yaw, pitch, dist}:
      R.Cam{
        R.Cam.yaw_step(yaw, (Delta(x, mx) * Ui.GAIN() : U32),
          U32.is_gt(x, mx)),
        R.Cam.pitch_step(pitch, (Delta(y, my) * Ui.GAIN() : U32),
          U32.is_gt(y, my)),
        dist}

def St.move.go(drag: Drag, +x: U32, +y: U32, +mx: U32, +my: U32, shift: Bool,
  cam: R.Cam, balls: S.Blobs, seed: U32, live: Bool) -> St:
  match drag:
    case DNone{}:
      St{cam, Ptr{DNone{}, x, y, shift}, balls, seed, live}
    case DOrbit{}:
      St{St.turn(cam, x, y, mx, my), Ptr{DOrbit{}, x, y, shift}, balls, seed,
        live}
    case DZoom{}:
      # Dragging down pulls the camera back.
      St{St.dolly(cam, (Delta(y, my) * Ui.DOLLY() : U32), U32.is_gt(y, my)),
        Ptr{DZoom{}, x, y, shift}, balls, seed, live}

def St.move(x: U32, y: U32, s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      match ptr:
        case Ptr{drag, mx, my, shift}:
          St.move.go(drag, x, y, mx, my, shift, cam, balls, seed, live)

def St.press.set(d: Drag, x: U32, y: U32, s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      match ptr:
        case Ptr{drag, mx, my, shift}:
          St{cam, Ptr{d, x, y, shift}, balls, seed, live}

# A shift-click drops a ball instead of starting a drag.
def St.press.go(down: Bool, shifted: Bool, button: U32, x: U32, y: U32,
  s: St) -> St:
  match down shifted:
    case True{} True{}:
      Spawn.add(s, x, y)
    case True{} False{}:
      St.press.set(Drag.of(button), x, y, s)
    case False{} _:
      St.press.set(DNone{}, x, y, s)

def St.shifted(s: St) -> Bool:
  match s:
    case St{cam, ptr, balls, seed, live}:
      match ptr:
        case Ptr{drag, mx, my, +shift}:
          shift

def St.press(x: U32, y: U32, button: U32, down: Bool, +s: St) -> St:
  St.press.go(down, St.shifted(s), button, x, y, s)

# -- Keys ---------------------------------------------------------------------

def St.set_shift(on: Bool, s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      match ptr:
        case Ptr{drag, mx, my, shift}:
          St{cam, Ptr{drag, mx, my, on}, balls, seed, live}

def St.set_cam(c: R.Cam, s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      St{c, ptr, balls, seed, live}

def St.cam.of(s: St) -> R.Cam:
  match s:
    case St{+cam, ptr, balls, seed, live}:
      cam

def St.kill(s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      St{cam, ptr, balls, seed, False{}}

def St.zoom(s: St, inward: Bool) -> St:
  +s = s
  St.set_cam(St.dolly(St.cam.of(s), Ui.ZOOM(), inward), s)

def St.key.go(quit: Bool, zin: Bool, zout: Bool, s: St) -> St:
  match quit zin zout:
    case True{} _ _:
      St.kill(s)
    case False{} True{} _:
      St.zoom(s, False{})
    case False{} False{} True{}:
      St.zoom(s, True{})
    case False{} False{} False{}:
      s

def St.key.act(act: Bool, +code: U32, s: St) -> St:
  match act:
    case False{}:
      s
    case True{}:
      St.key.go(U32.is_eq(code, Ui.KEY_ESC()), U32.is_eq(code, Ui.KEY_UP()),
        U32.is_eq(code, Ui.KEY_DOWN()), s)

def St.key.shift(is_shift: Bool, down: Bool, +code: U32, s: St) -> St:
  match is_shift:
    case True{}:
      St.set_shift(down, s)
    case False{}:
      St.key.act(down, code, s)

def St.key(+code: U32, down: Bool, s: St) -> St:
  St.key.shift(
    Bool.or(U32.is_eq(code, Ui.KEY_SHIFT_L()),
      U32.is_eq(code, Ui.KEY_SHIFT_R())), down, code, s)

# -- The event fold -----------------------------------------------------------

def St.done.go(live: Bool, cam: R.Cam, ptr: Ptr, balls: S.Blobs,
  seed: U32) -> Maybe<St>:
  match live:
    case True{}:
      Some{St{cam, ptr, balls, seed, True{}}}
    case False{}:
      None{}

# Takes the state apart and puts it back rather than marking it `+` and using
# it twice: marking a record reusable to read one field out of it is not free.
def St.done(s: St) -> Maybe<St>:
  match s:
    case St{cam, ptr, balls, seed, live}:
      St.done.go(live, cam, ptr, balls, seed)

# The dispatch is written out inside the loop because Bend forbids mutual
# recursion, so a per-event helper could not call back here.
def St.step(evs: List<Event>, s: St) -> Maybe<St>:
  match evs:
    case Nil{}:
      St.done(s)
    case Con{e, rest}:
      match e:
        case Close{}:
          None{}
        case Key{code, down}:
          St.step(rest, St.key(code, down, s))
        case Mouse{x, y, button, down}:
          St.step(rest, St.press(x, y, button, down, s))
        case Move{x, y}:
          St.step(rest, St.move(x, y, s))

# -- The App ------------------------------------------------------------------

def St.physics(s: St) -> St:
  match s:
    case St{cam, ptr, balls, seed, live}:
      St{cam, ptr, P.Phys.step(balls), seed, live}

def St.advance(m: Maybe<St>) -> Maybe<St>:
  match m:
    case None{}:
      None{}
    case Some{s}:
      Some{St.physics(s)}

def View(s: St) -> Pair(St, Image):
  match s:
    case St{cam, ptr, +balls, seed, live}:
      +cam = cam
      (St{cam, ptr, balls, seed, live},
        R.Render.frame(cam, P.Phys.cloud(balls)))

def Tick(evs: List<Event>, s: St) -> IO(Maybe<St>):
  IO.pure(Maybe<St>, St.advance(St.step(evs, s)))

def main() -> IO(Unit):
  App.run(~St, ~App{View, Tick}, "Bend Ray Tracer", R.Render.WIDTH(),
    R.Render.HEIGHT(), St.init())
