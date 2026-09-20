# The interactive viewer: an App whose view renders a frame and whose tick
# folds the window's events into the camera.
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

# Mouse pixels to tenths of a degree: a 1000-pixel drag sweeps about 200
# degrees.
def Ui.GAIN() -> U32:
  2

# Right-drag pixels to hundredths of a world unit: a 500-pixel drag covers
# most of the legal range.
def Ui.DOLLY() -> U32:
  4

# One arrow-key press, in hundredths of a world unit.
def Ui.ZOOM() -> U32:
  60

def Ui.KEY_ESC() -> U32:
  27

def Ui.KEY_UP() -> U32:
  63232

def Ui.KEY_DOWN() -> U32:
  63233

# Which button is currently held, if any.
type Drag is Data:
  DNone{}
  DOrbit{}
  DZoom{}

type St is Data:
  St{cam: R.Cam, drag: Drag, mx: U32, my: U32, live: Bool}

def St.init() -> St:
  St{R.Cam{450, 1005, 780}, DNone{}, 0, 0, True{}}

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

def St.move.go(drag: Drag, +x: U32, +y: U32, cam: R.Cam, +mx: U32, +my: U32,
  live: Bool) -> St:
  match drag:
    case DNone{}:
      St{cam, DNone{}, x, y, live}
    case DOrbit{}:
      St{St.turn(cam, x, y, mx, my), DOrbit{}, x, y, live}
    case DZoom{}:
      # Dragging down pulls the camera back.
      St{St.dolly(cam, (Delta(y, my) * Ui.DOLLY() : U32), U32.is_gt(y, my)),
        DZoom{}, x, y, live}

def St.move(x: U32, y: U32, s: St) -> St:
  match s:
    case St{cam, drag, mx, my, live}:
      St.move.go(drag, x, y, cam, mx, my, live)

# Pressing starts a drag, releasing ends it.
def St.press.go(down: Bool, button: U32, x: U32, y: U32, cam: R.Cam,
  live: Bool) -> St:
  match down:
    case True{}:
      St{cam, Drag.of(button), x, y, live}
    case False{}:
      St{cam, DNone{}, x, y, live}

def St.press(x: U32, y: U32, button: U32, down: Bool, s: St) -> St:
  match s:
    case St{cam, drag, mx, my, live}:
      St.press.go(down, button, x, y, cam, live)

def St.key.go(quit: Bool, zin: Bool, zout: Bool, cam: R.Cam, drag: Drag,
  mx: U32, my: U32, live: Bool) -> St:
  match quit zin zout:
    case True{} _ _:
      St{cam, drag, mx, my, False{}}
    case False{} True{} _:
      St{St.dolly(cam, Ui.ZOOM(), False{}), drag, mx, my, live}
    case False{} False{} True{}:
      St{St.dolly(cam, Ui.ZOOM(), True{}), drag, mx, my, live}
    case False{} False{} False{}:
      St{cam, drag, mx, my, live}

def St.key.act(act: Bool, +code: U32, cam: R.Cam, drag: Drag, mx: U32,
  my: U32, live: Bool) -> St:
  match act:
    case False{}:
      St{cam, drag, mx, my, live}
    case True{}:
      St.key.go(U32.is_eq(code, Ui.KEY_ESC()), U32.is_eq(code, Ui.KEY_UP()),
        U32.is_eq(code, Ui.KEY_DOWN()), cam, drag, mx, my, live)

def St.key(code: U32, down: Bool, s: St) -> St:
  match s:
    case St{cam, drag, mx, my, live}:
      St.key.act(down, code, cam, drag, mx, my, live)

# Takes the state apart and puts it back rather than marking it `+` and using
# it twice: marking a record reusable to read one field out of it is not free.
def St.done.go(live: Bool, cam: R.Cam, drag: Drag, mx: U32, my: U32) ->
  Maybe<St>:
  match live:
    case True{}:
      Some{St{cam, drag, mx, my, True{}}}
    case False{}:
      None{}

def St.done(s: St) -> Maybe<St>:
  match s:
    case St{cam, drag, mx, my, live}:
      St.done.go(live, cam, drag, mx, my)

# The event fold. The dispatch is written out inside the loop because Bend
# forbids mutual recursion, so a per-event helper could not call back here.
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

def View(s: St) -> Pair(St, Image):
  match s:
    case St{cam, drag, mx, my, live}:
      +cam = cam
      (St{cam, drag, mx, my, live}, R.Render.frame(cam))

def Tick(evs: List<Event>, s: St) -> IO(Maybe<St>):
  IO.pure(Maybe<St>, St.step(evs, s))

def main() -> IO(Unit):
  App.run(~St, ~App{View, Tick}, "Bend Ray Tracer", R.Render.WIDTH(),
    R.Render.HEIGHT(), St.init())
