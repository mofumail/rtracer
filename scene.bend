# Scene: geometry, materials, lighting and the reflection recursion.
#
# The scene is a ground plane plus five spheres, written out by hand rather
# than held in a list. Unrolling it keeps every ray doing the same work, which
# is what the GPU wants: a list fold would make the cost depend on how early a
# ray hits something, and lanes that disagree run serially.
#
# Bend cannot `match` a computed value, only a parameter or a pattern variable.
# That is why each test below (`disc < 0`, `t > eps`, ...) is a small def that
# takes the Bool and matches on it. Helpers are defined before their callers,
# since Bend resolves names in file order.

import Base
import ./vec.bend as V

# A ray's nearest intersection, with the surface it landed on.
type Hit is Data:
  Miss{}
  Near{t: F32, pos: V.V3, nrm: V.V3, alb: V.V3, refl: F32}

def Scene.EPS() -> F32:
  0.001

def Scene.FAR() -> F32:
  100000.0

# The reflection recursion is capped here; `Laws.bounce_depth` proves the
# tracer never goes deeper than this.
def Scene.MAX_DEPTH() -> Nat:
  3n

# Direction *towards* the light, pre-normalized.
def Scene.light() -> V.V3:
  V.V3.norm(V.V3{F32.neg(0.38), 0.86, 0.34})

def Scene.sun() -> V.V3:
  V.V3{1.18, 1.12, 0.98}

def Scene.ambient() -> V.V3:
  V.V3{0.13, 0.16, 0.23}

# A simple vertical gradient stands in for an environment map.
def Scene.sky(rd: V.V3) -> V.V3:
  match rd:
    case V.V3{x, y, z}:
      +t = F32.clamp((0.5 * y + 0.5 : F32), 0.0, 1.0)
      V.V3.lerp(V.V3{0.62, 0.70, 0.82}, V.V3{0.16, 0.32, 0.62}, t)

# Keeps the nearer of two hits.
def Hit.pick(first: Bool, a: Hit, b: Hit) -> Hit:
  match first:
    case True{}:
      a
    case False{}:
      b

def Hit.closer(a: Hit, b: Hit) -> Hit:
  match a b:
    case Miss{} Miss{}:
      Miss{}
    case Miss{} Near{t, pos, nrm, alb, refl}:
      Near{t, pos, nrm, alb, refl}
    case Near{t, pos, nrm, alb, refl} Miss{}:
      Near{t, pos, nrm, alb, refl}
    case Near{+ta, pa, na, aa, ra} Near{+tb, pb, nb, ab, rb}:
      Hit.pick(F32.is_lt(ta, tb), Near{ta, pa, na, aa, ra},
        Near{tb, pb, nb, ab, rb})

# -- Ground plane, y = 0 ------------------------------------------------------

def Plane.hit.at(ok: Bool, +t: F32, ro: V.V3, rd: V.V3, alb: V.V3, +refl: F32)
  -> Hit:
  match ok:
    case False{}:
      Miss{}
    case True{}:
      Near{t, V.V3.add(ro, V.V3.scale(rd, t)), V.V3{0.0, 1.0, 0.0}, alb, refl}

def Plane.hit(ro: V.V3, rd: V.V3, alb: V.V3, +refl: F32) -> Hit:
  match ro rd:
    case V.V3{ox, oy, oz} V.V3{dx, dy, dz}:
      +oy = oy
      +dy = dy
      # A ray parallel to the plane divides by zero; the range guard below
      # rejects the infinity that produces, so no special case is needed.
      +t = (F32.neg(oy) / dy : F32)
      Plane.hit.at(
        Bool.and(F32.is_gt(t, Scene.EPS()), F32.is_lt(t, Scene.FAR())),
        t, V.V3{ox, oy, oz}, V.V3{dx, dy, dz}, alb, refl)

# -- Spheres ------------------------------------------------------------------

def Sph.hit.at(+t: F32, ro: V.V3, rd: V.V3, ctr: V.V3, alb: V.V3, +refl: F32)
  -> Hit:
  +pos = V.V3.add(ro, V.V3.scale(rd, t))
  Near{t, pos, V.V3.norm(V.V3.sub(pos, ctr)), alb, refl}

# Picks the near root, then the far one (for a ray starting inside), then
# gives up.
def Sph.hit.root(near: Bool, far: Bool, +t0: F32, +t1: F32, ro: V.V3,
  rd: V.V3, ctr: V.V3, alb: V.V3, +refl: F32) -> Hit:
  match near far:
    case True{} _:
      Sph.hit.at(t0, ro, rd, ctr, alb, refl)
    case False{} True{}:
      Sph.hit.at(t1, ro, rd, ctr, alb, refl)
    case False{} False{}:
      Miss{}

def Sph.hit.disc(miss: Bool, +disc: F32, +b: F32, ro: V.V3, rd: V.V3,
  ctr: V.V3, alb: V.V3, +refl: F32) -> Hit:
  match miss:
    case True{}:
      Miss{}
    case False{}:
      +sq = F32.sqrt(disc)
      +t0 = (F32.neg(b) - sq : F32)
      +t1 = (F32.neg(b) + sq : F32)
      Sph.hit.root(F32.is_gt(t0, Scene.EPS()), F32.is_gt(t1, Scene.EPS()),
        t0, t1, ro, rd, ctr, alb, refl)

# `rd` is unit length, so the quadratic's leading coefficient is 1 and the
# discriminant is just b^2 - c.
def Sph.hit(+ro: V.V3, +rd: V.V3, +ctr: V.V3, +rad: F32, alb: V.V3,
  +refl: F32) -> Hit:
  +oc = V.V3.sub(ro, ctr)
  +b = V.V3.dot(oc, rd)
  +c = (V.V3.dot2(oc) - rad * rad : F32)
  +disc = (b * b - c : F32)
  Sph.hit.disc(F32.is_lt(disc, 0.0), disc, b, ro, rd, ctr, alb, refl)

# -- The scene itself ---------------------------------------------------------

# One mirror, one glossy metal, three diffuse, on a faintly reflective floor.
def Scene.hit(+ro: V.V3, +rd: V.V3) -> Hit:
  h0 = Plane.hit(ro, rd, V.V3{0.46, 0.46, 0.50}, 0.16)
  h1 = Sph.hit(ro, rd, V.V3{0.0, 1.0, 0.0}, 1.0, V.V3{0.95, 0.96, 0.98}, 0.88)
  h2 = Sph.hit(ro, rd, V.V3{F32.neg(2.4), 0.6, 0.9}, 0.6,
    V.V3{0.88, 0.22, 0.18}, 0.0)
  h3 = Sph.hit(ro, rd, V.V3{2.3, 0.75, 0.3}, 0.75,
    V.V3{0.22, 0.40, 0.90}, 0.05)
  h4 = Sph.hit(ro, rd, V.V3{1.1, 0.4, 2.1}, 0.4, V.V3{0.96, 0.74, 0.28},
    0.5)
  h5 = Sph.hit(ro, rd, V.V3{F32.neg(1.2), 0.45, 2.2}, 0.45,
    V.V3{0.28, 0.74, 0.34}, 0.0)
  Hit.closer(Hit.closer(h0, h1), Hit.closer(Hit.closer(h2, h3),
    Hit.closer(h4, h5)))

# -- Shading ------------------------------------------------------------------

# A shadow ray that hits nothing leaves the point fully lit.
def Shade.lit(h: Hit) -> F32:
  match h:
    case Miss{}:
      1.0
    case Near{t, pos, nrm, alb, refl}:
      0.0

# Lambert against the one directional light, a hard shadow, and a constant
# ambient term so surfaces facing away are not pure black.
def Shade.local(pos: V.V3, +nrm: V.V3, alb: V.V3) -> V.V3:
  +l = Scene.light()
  +ndl = F32.max(V.V3.dot(nrm, l), 0.0)
  +vis = Shade.lit(Scene.hit(V.V3.add(pos, V.V3.scale(nrm, Scene.EPS())), l))
  V.V3.mul(alb,
    V.V3.add(Scene.ambient(), V.V3.scale(Scene.sun(), (ndl * vis : F32))))

# The reflected ray leaving a surface, as two defs rather than one returning a
# pair: Bend cannot destructure a computed tuple. `Trace` and `Trace.depth`
# both call these, so the two recursions step in lockstep and the depth law
# says something about the renderer rather than about a separate copy of it.
def Trace.org(pos: V.V3, nrm: V.V3) -> V.V3:
  V.V3.add(pos, V.V3.scale(nrm, Scene.EPS()))

def Trace.dir(rd: V.V3, nrm: V.V3) -> V.V3:
  V.V3.norm(V.V3.reflect(rd, nrm))

# -- The reflection recursion -------------------------------------------------

# `d` is the bounce budget and shrinks on every call, so Bend's termination
# check alone bounds the recursion; `Trace.depth` below makes that bound
# something the laws can state.
#
# The hit is a parameter rather than something computed inside, because Bend
# only matches parameters and pattern variables.
def Trace(d: Nat, h: Hit, ro: V.V3, rd: V.V3) -> V.V3:
  match d:
    case 0n:
      match h:
        case Miss{}:
          Scene.sky(rd)
        case Near{t, pos, nrm, alb, refl}:
          Shade.local(pos, nrm, alb)
    case 1n+p:
      match h:
        case Miss{}:
          Scene.sky(rd)
        case Near{t, +pos, +nrm, alb, +refl}:
          base = Shade.local(pos, nrm, alb)
          +ro2 = Trace.org(pos, nrm)
          +rd2 = Trace.dir(rd, nrm)
          echo = Trace(p, Scene.hit(ro2, rd2), ro2, rd2)
          V.V3.lerp(base, echo, F32.clamp(refl, 0.0, 1.0))

# Counts the bounces `Trace` takes on the same inputs. It exists only so the
# laws can talk about recursion depth: a function returning a colour gives the
# proof nothing to measure.
def Trace.depth(d: Nat, h: Hit, ro: V.V3, rd: V.V3) -> Nat:
  match d:
    case 0n:
      match h:
        case Miss{}:
          0n
        case Near{t, pos, nrm, alb, refl}:
          0n
    case 1n+p:
      match h:
        case Miss{}:
          0n
        case Near{t, +pos, +nrm, alb, refl}:
          +ro2 = Trace.org(pos, nrm)
          +rd2 = Trace.dir(rd, nrm)
          1n+Trace.depth(p, Scene.hit(ro2, rd2), ro2, rd2)

# The entry point: one primary ray in, one colour out.
def Trace.start(+ro: V.V3, +rd: V.V3) -> V.V3:
  Trace(Scene.MAX_DEPTH(), Scene.hit(ro, rd), ro, rd)
