# Scene: geometry, materials, lighting and the reflection recursion.
#
# The scene is a ground plane plus five spheres, written out by hand rather
# than held in a list. Unrolling it keeps every ray doing the same work, which
# is what the GPU wants: a list fold would make the cost depend on how early a
# ray hits something, and lanes that disagree run serially.
#
# Three things here exist for speed, and shape the code:
#
#   * Intersection returns a `Cand` -- a distance plus the material and the
#     sphere's centre -- and the hit position and normal are computed once,
#     for the winner only. Normalizing a normal costs a sqrt, and the old
#     version paid it for every object a ray hit and then threw all but one
#     away.
#   * Shadow rays use `Scene.shadowed`, which answers a Bool and never builds
#     a record, computes a position or normalizes anything. A shadow ray only
#     ever asked "is something in the way".
#   * A surface facing away from the light is in shadow already, so the ray is
#     skipped entirely when N.L <= 0.
#
# Bend cannot `match` a computed value, only a parameter or a pattern
# variable. That is why each test below is a small def taking the Bool, and
# why `Trace` receives its "keep bouncing" decision as a parameter: the branch
# has to live inside the recursive def, because a helper that made the
# decision and then called `Trace` would be mutual recursion, which Bend
# forbids.

import Base
import ./vec.bend as V

# A candidate intersection. `ctr` is the sphere's centre, used to build the
# normal later; `flat` marks the ground plane, whose normal is constant.
type Cand is Data:
  Void{}
  Cand{t: F32, ctr: V.V3, alb: V.V3, refl: F32, flat: Bool}

# A ball the user dropped into the scene. Same shape as a static sphere, plus
# the state the physics needs. `id` is what lets a ball skip itself when it
# collides against the rest of the list.
type Ball is Data:
  Ball{id: U32, pos: V.V3, vel: V.V3, rad: F32, alb: V.V3, refl: F32}

# A monomorphic list of balls rather than Base's `List<&2, Ball>`. The
# polymorphic one is carried through the whole tracer, and every bounce
# duplicates it; specialising it here is worth more than it looks.
type Blobs is Data:
  BNil{}
  BCons{head: Ball, tail: Blobs}

# The balls plus a sphere enclosing all of them. Every ray tests the bound
# once and skips the whole list when it misses, which is most rays: the sky,
# the distant floor, and shadow rays pointing up and away. Without it each
# ball costs an intersection on every bounce and every shadow ray of every
# pixel, which measured ~23 ms per ball at 1920x1080.
type Cloud is Data:
  Cloud{ctr: V.V3, rad: F32, items: Blobs}

def Scene.EPS() -> F32:
  0.001

def Scene.FAR() -> F32:
  100000.0

# The reflection recursion is capped here; `Laws.bounce_depth` proves the
# tracer never goes deeper than this.
def Scene.MAX_DEPTH() -> Nat:
  3n

# A bounce whose contribution would fall below this is not taken. A matte
# sphere seen in the floor ends the chain immediately instead of running the
# budget out, which is most of the speed-up at depth 3.
def Scene.MIN_W() -> F32:
  0.015

# Direction *towards* the light, pre-normalized.
def Scene.light() -> V.V3:
  V.V3.norm(V.V3{F32.neg(0.38), 0.86, 0.34})

def Scene.sun() -> V.V3:
  V.V3{1.18, 1.12, 0.98}

def Scene.ambient() -> V.V3:
  V.V3{0.13, 0.16, 0.23}

# -- The scene's objects, named once and shared by both traversals ------------

def Scene.c1() -> V.V3:
  V.V3{0.0, 1.0, 0.0}

def Scene.r1() -> F32:
  1.0

def Scene.c2() -> V.V3:
  V.V3{F32.neg(2.4), 0.6, 0.9}

def Scene.r2() -> F32:
  0.6

def Scene.c3() -> V.V3:
  V.V3{2.3, 0.75, 0.3}

def Scene.r3() -> F32:
  0.75

def Scene.c4() -> V.V3:
  V.V3{1.1, 0.4, 2.1}

def Scene.r4() -> F32:
  0.4

def Scene.c5() -> V.V3:
  V.V3{F32.neg(1.2), 0.45, 2.2}

def Scene.r5() -> F32:
  0.45

# A simple vertical gradient stands in for an environment map.
def Scene.sky(rd: V.V3) -> V.V3:
  match rd:
    case V.V3{x, y, z}:
      +t = F32.clamp((0.5 * y + 0.5 : F32), 0.0, 1.0)
      V.V3.lerp(V.V3{0.62, 0.70, 0.82}, V.V3{0.16, 0.32, 0.62}, t)

# -- Nearest-hit traversal ----------------------------------------------------

def Cand.pick(first: Bool, a: Cand, b: Cand) -> Cand:
  match first:
    case True{}:
      a
    case False{}:
      b

def Cand.closer(a: Cand, b: Cand) -> Cand:
  match a b:
    case Void{} Void{}:
      Void{}
    case Void{} Cand{t, ctr, alb, refl, flat}:
      Cand{t, ctr, alb, refl, flat}
    case Cand{t, ctr, alb, refl, flat} Void{}:
      Cand{t, ctr, alb, refl, flat}
    case Cand{+ta, pa, aa, ra, fa} Cand{+tb, pb, ab, rb, fb}:
      Cand.pick(F32.is_lt(ta, tb), Cand{ta, pa, aa, ra, fa},
        Cand{tb, pb, ab, rb, fb})

def Plane.cand.at(ok: Bool, +t: F32, alb: V.V3, +refl: F32) -> Cand:
  match ok:
    case False{}:
      Void{}
    case True{}:
      Cand{t, V.V3{0.0, 0.0, 0.0}, alb, refl, True{}}

def Plane.cand(ro: V.V3, rd: V.V3, alb: V.V3, +refl: F32) -> Cand:
  match ro rd:
    case V.V3{ox, oy, oz} V.V3{dx, dy, dz}:
      # A ray parallel to the plane divides by zero; the range guard rejects
      # the infinity that produces, so no special case is needed.
      +t = (F32.neg(oy) / dy : F32)
      Plane.cand.at(
        Bool.and(F32.is_gt(t, Scene.EPS()), F32.is_lt(t, Scene.FAR())),
        t, alb, refl)

def Sph.cand.root(near: Bool, far: Bool, +t0: F32, +t1: F32, ctr: V.V3,
  alb: V.V3, +refl: F32) -> Cand:
  match near far:
    case True{} _:
      Cand{t0, ctr, alb, refl, False{}}
    case False{} True{}:
      Cand{t1, ctr, alb, refl, False{}}
    case False{} False{}:
      Void{}

def Sph.cand.disc(miss: Bool, +disc: F32, +b: F32, ctr: V.V3, alb: V.V3,
  +refl: F32) -> Cand:
  match miss:
    case True{}:
      Void{}
    case False{}:
      +sq = F32.sqrt(disc)
      +t0 = (F32.neg(b) - sq : F32)
      +t1 = (F32.neg(b) + sq : F32)
      Sph.cand.root(F32.is_gt(t0, Scene.EPS()), F32.is_gt(t1, Scene.EPS()),
        t0, t1, ctr, alb, refl)

# `rd` is unit length, so the quadratic's leading coefficient is 1 and the
# discriminant is just b^2 - c.
def Sph.cand(ro: V.V3, rd: V.V3, +ctr: V.V3, +rad: F32, alb: V.V3,
  +refl: F32) -> Cand:
  +oc = V.V3.sub(ro, ctr)
  +b = V.V3.dot(oc, rd)
  +c = (V.V3.dot2(oc) - rad * rad : F32)
  +disc = (b * b - c : F32)
  Sph.cand.disc(F32.is_lt(disc, 0.0), disc, b, ctr, alb, refl)

def Ball.cand(b: Ball, ro: V.V3, rd: V.V3) -> Cand:
  match b:
    case Ball{id, pos, vel, rad, alb, refl}:
      Sph.cand(ro, rd, pos, rad, alb, refl)

# Every ray walks the whole list, so the cost is the same for all of them and
# the split stays balanced -- the thing Bend's scheduler cares about.
def Balls.find(bs: Blobs, +ro: V.V3, +rd: V.V3) -> Cand:
  match bs:
    case BNil{}:
      Void{}
    case BCons{b, tl}:
      Cand.closer(Ball.cand(b, ro, rd), Balls.find(tl, ro, rd))

# A shadow ray only needs a yes or no, so nothing here builds a record or
# normalizes a vector. The light is directional, so any root past EPS blocks.
def Sph.blocks.go(miss: Bool, +disc: F32, +b: F32) -> Bool:
  match miss:
    case True{}:
      False{}
    case False{}:
      F32.is_gt((F32.neg(b) + F32.sqrt(disc) : F32), Scene.EPS())

def Sph.blocks(ro: V.V3, rd: V.V3, ctr: V.V3, +rad: F32) -> Bool:
  +oc = V.V3.sub(ro, ctr)
  +b = V.V3.dot(oc, rd)
  +c = (V.V3.dot2(oc) - rad * rad : F32)
  +disc = (b * b - c : F32)
  Sph.blocks.go(F32.is_lt(disc, 0.0), disc, b)

def Cloud.find.go(near: Bool, items: Blobs, ro: V.V3, rd: V.V3) -> Cand:
  match near:
    case False{}:
      Void{}
    case True{}:
      Balls.find(items, ro, rd)

# An empty cloud short-circuits on a constructor match rather than paying for
# the bound intersection, so a scene with no dropped balls costs exactly what
# it did before the feature existed.
def Cloud.find(c: Cloud, +ro: V.V3, +rd: V.V3) -> Cand:
  match c:
    case Cloud{ctr, rad, items}:
      match items:
        case BNil{}:
          Void{}
        case BCons{h, t}:
          Cloud.find.go(Sph.blocks(ro, rd, ctr, rad), BCons{h, t}, ro, rd)

# One mirror, one glossy metal, three diffuse, on a faintly reflective floor,
# plus whatever the user has dropped in.
def Scene.find(+balls: Cloud, +ro: V.V3, +rd: V.V3) -> Cand:
  h0 = Plane.cand(ro, rd, V.V3{0.46, 0.46, 0.50}, 0.16)
  h1 = Sph.cand(ro, rd, Scene.c1(), Scene.r1(), V.V3{0.95, 0.96, 0.98}, 0.88)
  h2 = Sph.cand(ro, rd, Scene.c2(), Scene.r2(), V.V3{0.88, 0.22, 0.18}, 0.0)
  h3 = Sph.cand(ro, rd, Scene.c3(), Scene.r3(), V.V3{0.22, 0.40, 0.90}, 0.05)
  h4 = Sph.cand(ro, rd, Scene.c4(), Scene.r4(), V.V3{0.96, 0.74, 0.28}, 0.5)
  h5 = Sph.cand(ro, rd, Scene.c5(), Scene.r5(), V.V3{0.28, 0.74, 0.34}, 0.0)
  Cand.closer(Cand.closer(Cand.closer(h0, h1), Cloud.find(balls, ro, rd)),
    Cand.closer(Cand.closer(h2, h3), Cand.closer(h4, h5)))

# -- Occlusion-only traversal -------------------------------------------------

def Plane.blocks(ro: V.V3, rd: V.V3) -> Bool:
  match ro rd:
    case V.V3{ox, oy, oz} V.V3{dx, dy, dz}:
      +t = (F32.neg(oy) / dy : F32)
      Bool.and(F32.is_gt(t, Scene.EPS()), F32.is_lt(t, Scene.FAR()))

def Ball.blocks(b: Ball, ro: V.V3, rd: V.V3) -> Bool:
  match b:
    case Ball{id, pos, vel, rad, alb, refl}:
      Sph.blocks(ro, rd, pos, rad)

def Balls.shadowed(bs: Blobs, +ro: V.V3, +rd: V.V3) -> Bool:
  match bs:
    case BNil{}:
      False{}
    case BCons{b, tl}:
      Bool.or(Ball.blocks(b, ro, rd), Balls.shadowed(tl, ro, rd))

def Cloud.shadowed.go(near: Bool, items: Blobs, ro: V.V3, rd: V.V3) -> Bool:
  match near:
    case False{}:
      False{}
    case True{}:
      Balls.shadowed(items, ro, rd)

def Cloud.shadowed(c: Cloud, +ro: V.V3, +rd: V.V3) -> Bool:
  match c:
    case Cloud{ctr, rad, items}:
      match items:
        case BNil{}:
          False{}
        case BCons{h, t}:
          Cloud.shadowed.go(Sph.blocks(ro, rd, ctr, rad), BCons{h, t}, ro, rd)

def Scene.shadowed(+balls: Cloud, +ro: V.V3, +rd: V.V3) -> Bool:
  Bool.or(Cloud.shadowed(balls, ro, rd),
  Bool.or(
    Bool.or(Plane.blocks(ro, rd),
      Sph.blocks(ro, rd, Scene.c1(), Scene.r1())),
    Bool.or(
      Bool.or(Sph.blocks(ro, rd, Scene.c2(), Scene.r2()),
        Sph.blocks(ro, rd, Scene.c3(), Scene.r3())),
      Bool.or(Sph.blocks(ro, rd, Scene.c4(), Scene.r4()),
        Sph.blocks(ro, rd, Scene.c5(), Scene.r5())))))

# -- Shading ------------------------------------------------------------------

def Shade.vis.of(blocked: Bool) -> F32:
  match blocked:
    case True{}:
      0.0
    case False{}:
      1.0

# Only cast the shadow ray when the surface actually faces the light.
def Shade.vis(lit: Bool, balls: Cloud, pos: V.V3, nrm: V.V3, l: V.V3) ->
  F32:
  match lit:
    case False{}:
      0.0
    case True{}:
      Shade.vis.of(
        Scene.shadowed(balls, V.V3.add(pos, V.V3.scale(nrm, Scene.EPS())), l))

# Lambert against the one directional light, a hard shadow, and a constant
# ambient term so surfaces facing away are not pure black.
def Shade.local(balls: Cloud, pos: V.V3, +nrm: V.V3, alb: V.V3) -> V.V3:
  +l = Scene.light()
  +ndl = F32.max(V.V3.dot(nrm, l), 0.0)
  +vis = Shade.vis(F32.is_gt(ndl, 0.0), balls, pos, nrm, l)
  V.V3.mul(alb,
    V.V3.add(Scene.ambient(), V.V3.scale(Scene.sun(), (ndl * vis : F32))))

# The plane's normal is constant; a sphere's needs the hit position.
def Cand.nrm(flat: Bool, pos: V.V3, ctr: V.V3) -> V.V3:
  match flat:
    case True{}:
      V.V3{0.0, 1.0, 0.0}
    case False{}:
      V.V3.norm(V.V3.sub(pos, ctr))

def Cand.refl(c: Cand) -> F32:
  match c:
    case Void{}:
      0.0
    case Cand{t, ctr, alb, refl, flat}:
      refl

# The reflected ray leaving a surface, as two defs rather than one returning a
# pair: Bend cannot destructure a computed tuple. `Trace` and `Trace.depth`
# both call these, so the two recursions step in lockstep.
def Trace.org(pos: V.V3, nrm: V.V3) -> V.V3:
  V.V3.add(pos, V.V3.scale(nrm, Scene.EPS()))

def Trace.dir(rd: V.V3, nrm: V.V3) -> V.V3:
  V.V3.norm(V.V3.reflect(rd, nrm))

# Shading with no further bounce: the end of a chain.
def Trace.leaf(balls: Cloud, c: Cand, ro: V.V3, rd: V.V3) -> V.V3:
  match c:
    case Void{}:
      Scene.sky(rd)
    case Cand{+t, ctr, alb, refl, flat}:
      +pos = V.V3.add(ro, V.V3.scale(rd, t))
      Shade.local(balls, pos, Cand.nrm(flat, pos, ctr), alb)

# -- The reflection recursion -------------------------------------------------

# `d` is the bounce budget and shrinks on every call, so Bend's termination
# check alone bounds the recursion; `Trace.depth` makes that bound something
# the laws can state.
#
# `go` carries the decision of whether this bounce is worth taking, computed
# by the caller from the running weight -- the branch cannot be factored into
# a helper, because that helper would have to call `Trace` back.
def Trace(d: Nat, go: Bool, c: Cand, ro: V.V3, +rd: V.V3, w: F32,
  +balls: Cloud) -> V.V3:
  match d:
    case 0n:
      Trace.leaf(balls, c, ro, rd)
    case 1n+p:
      match go:
        case False{}:
          Trace.leaf(balls, c, ro, rd)
        case True{}:
          match c:
            case Void{}:
              Scene.sky(rd)
            case Cand{+t, ctr, alb, +refl, flat}:
              +pos = V.V3.add(ro, V.V3.scale(rd, t))
              +nrm = Cand.nrm(flat, pos, ctr)
              base = Shade.local(balls, pos, nrm, alb)
              +ro2 = Trace.org(pos, nrm)
              +rd2 = Trace.dir(rd, nrm)
              +c2 = Scene.find(balls, ro2, rd2)
              +w2 = (w * refl : F32)
              echo = Trace(p,
                F32.is_gt((w2 * Cand.refl(c2) : F32), Scene.MIN_W()), c2, ro2,
                rd2, w2, balls)
              V.V3.lerp(base, echo, F32.clamp(refl, 0.0, 1.0))

# Counts the bounces `Trace` takes on the same inputs, branching the same way.
# It exists only so the laws can talk about recursion depth: a function
# returning a colour gives the proof nothing to measure.
def Trace.depth(d: Nat, go: Bool, c: Cand, ro: V.V3, +rd: V.V3, w: F32,
  +balls: Cloud) -> Nat:
  match d:
    case 0n:
      0n
    case 1n+p:
      match go:
        case False{}:
          0n
        case True{}:
          match c:
            case Void{}:
              0n
            case Cand{+t, ctr, alb, +refl, flat}:
              +pos = V.V3.add(ro, V.V3.scale(rd, t))
              +nrm = Cand.nrm(flat, pos, ctr)
              +ro2 = Trace.org(pos, nrm)
              +rd2 = Trace.dir(rd, nrm)
              +c2 = Scene.find(balls, ro2, rd2)
              +w2 = (w * refl : F32)
              1n+Trace.depth(p,
                F32.is_gt((w2 * Cand.refl(c2) : F32), Scene.MIN_W()), c2, ro2,
                rd2, w2, balls)

# The entry point: one primary ray in, one colour out.
def Trace.start(+balls: Cloud, +ro: V.V3, +rd: V.V3) -> V.V3:
  +c = Scene.find(balls, ro, rd)
  Trace(Scene.MAX_DEPTH(), F32.is_gt(Cand.refl(c), Scene.MIN_W()), c, ro, rd,
    1.0, balls)
