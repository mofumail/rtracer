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

# A bounding volume hierarchy over the dropped balls, rebuilt once a frame.
#
# Each `BPair` stores its two children's bounding spheres inline, so a ray can
# reject a whole subtree without opening it -- opening it to read its bound
# would mean using the child twice, and a `+` on a node is a reference count
# on the hot path. A ray that would have tested 1000 balls tests about 20
# nodes instead.
type Bvh is Data:
  BEmpty{}
  BItems{items: Blobs}
  BPair{lc: V.V3, lr: F32, l: Bvh, rc: V.V3, rr: F32, r: Bvh}

# The balls plus a sphere enclosing all of them. Every ray tests the bound
# once and skips the whole list when it misses, which is most rays: the sky,
# the distant floor, and shadow rays pointing up and away. Without it each
# ball costs an intersection on every bounce and every shadow ray of every
# pixel, which measured ~23 ms per ball at 1920x1080.
type Cloud is Data:
  Cloud{ctr: V.V3, rad: F32, root: Bvh}

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

# -- Building the hierarchy ---------------------------------------------------
#
# Rebuilt from scratch every frame. That sounds wasteful next to 4.19M pixels,
# but it is O(n log n) on a list of hundreds, against O(n) work per ray for
# millions of rays -- the build does not show up in a frame time at all.
#
# The split is a k-d style one: rotate through x, y, z by depth and cut at the
# centroid on that axis. No sorting, no extent scan, and the centroid is
# already needed for the bounding sphere.

def Ball.pos(b: Ball) -> V.V3:
  match b:
    case Ball{id, pos, vel, rad, alb, refl}:
      pos

def Ball.rad(b: Ball) -> F32:
  match b:
    case Ball{id, pos, vel, rad, alb, refl}:
      rad

def V3.axis.go(isx: Bool, isy: Bool, x: F32, y: F32, z: F32) -> F32:
  match isx isy:
    case True{} True{}:
      x
    case True{} False{}:
      x
    case False{} True{}:
      y
    case False{} False{}:
      z

def V3.axis(v: V.V3, +a: U32) -> F32:
  match v:
    case V.V3{x, y, z}:
      V3.axis.go(U32.is_eq(a, 0), U32.is_eq(a, 1), x, y, z)

def Blobs.count(bs: Blobs, acc: F32) -> F32:
  match bs:
    case BNil{}:
      acc
    case BCons{b, tl}:
      Blobs.count(tl, (acc + 1.0 : F32))

def Blobs.sum(bs: Blobs, acc: V.V3) -> V.V3:
  match bs:
    case BNil{}:
      acc
    case BCons{b, tl}:
      Blobs.sum(tl, V.V3.add(acc, Ball.pos(b)))

def Blobs.reach(bs: Blobs, +c: V.V3, acc: F32) -> F32:
  match bs:
    case BNil{}:
      acc
    case BCons{+b, tl}:
      Blobs.reach(tl, c, F32.max(acc,
        (V.V3.len(V.V3.sub(Ball.pos(b), c)) + Ball.rad(b) : F32)))

def Blobs.centre.go(none: Bool, s: V.V3, +n: F32) -> V.V3:
  match none:
    case True{}:
      V.V3{0.0, 0.0, 0.0}
    case False{}:
      V.V3.scale(s, (1.0 / n : F32))

def Blobs.centre(+bs: Blobs) -> V.V3:
  +n = Blobs.count(bs, 0.0)
  Blobs.centre.go(F32.is_lt(n, 0.5), Blobs.sum(bs, V.V3{0.0, 0.0, 0.0}), n)

# True once a list is small enough to scan linearly instead of splitting.
def Blobs.small(+bs: Blobs) -> Bool:
  F32.is_lt(Blobs.count(bs, 0.0), 2.5)

# Two filter passes rather than one partition returning a pair: Bend cannot
# destructure a computed value, and a helper that split and then called the
# builder back would be mutual recursion. The extra walk is nothing here.
def Blobs.keep(keep: Bool, b: Ball, rest: Blobs) -> Blobs:
  match keep:
    case True{}:
      BCons{b, rest}
    case False{}:
      rest

def Blobs.below(bs: Blobs, +a: U32, +mid: F32) -> Blobs:
  match bs:
    case BNil{}:
      BNil{}
    case BCons{+b, tl}:
      Blobs.keep(F32.is_lt(V3.axis(Ball.pos(b), a), mid), b,
        Blobs.below(tl, a, mid))

def Blobs.above(bs: Blobs, +a: U32, +mid: F32) -> Blobs:
  match bs:
    case BNil{}:
      BNil{}
    case BCons{+b, tl}:
      Blobs.keep(Bool.not(F32.is_lt(V3.axis(Ball.pos(b), a), mid)), b,
        Blobs.above(tl, a, mid))

# How deep the tree may go. The fuel is also what makes the recursion
# terminate when a split degenerates -- every ball at the same point puts them
# all on one side, and nothing shrinks.
def Bvh.FUEL() -> Nat:
  16n

# `small` is computed by the caller: Bend forbids mutual recursion, so a
# helper that decided and then called back here is not available. `a` is the
# split axis, rotating x -> y -> z with depth.
def Bvh.build(fuel: Nat, small: Bool, +a: U32, +bs: Blobs) -> Bvh:
  match fuel:
    case 0n:
      BItems{bs}
    case 1n+f:
      match small:
        case True{}:
          BItems{bs}
        case False{}:
          +f = f
          +mid = V3.axis(Blobs.centre(bs), a)
          +lo = Blobs.below(bs, a, mid)
          +hi = Blobs.above(bs, a, mid)
          +a2 = ((a + 1 : U32) % 3 : U32)
          +lc = Blobs.centre(lo)
          +hc = Blobs.centre(hi)
          BPair{lc, Blobs.reach(lo, lc, 0.0),
            Bvh.build(f, Blobs.small(lo), a2, lo), hc,
            Blobs.reach(hi, hc, 0.0), Bvh.build(f, Blobs.small(hi), a2, hi)}

def Bvh.of(+bs: Blobs) -> Bvh:
  Bvh.build(Bvh.FUEL(), Blobs.small(bs), 0, bs)

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

# The running best is an accumulator so the recursive call sits in tail
# position, which Bend compiles to a loop. The old shape wrapped the call in
# `Cand.closer`, which is not a tail call: it built one continuation per ball
# per ray, and overflowed the machine stack somewhere past 128 balls.
def Balls.find(bs: Blobs, best: Cand, +ro: V.V3, +rd: V.V3) -> Cand:
  match bs:
    case BNil{}:
      best
    case BCons{b, tl}:
      Balls.find(tl, Cand.closer(Ball.cand(b, ro, rd), best), ro, rd)

# A shadow ray only needs a yes or no, so nothing here builds a record or
# normalizes a vector. The light is directional, so any root past EPS blocks.
#
# The walk carries the answer so far as a parameter: Bend is strict, so
# `Bool.or(test, recurse)` evaluated the whole list even after something
# blocked. Carrying it lets the walk stop at the first blocker, and puts the
# recursive call in tail position.
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

# Walks the hierarchy, carrying the best hit so far as an accumulator.
#
# `near` says whether the ray met this node's bounding sphere; the parent
# computes it from the child's bound, which it stores inline. That is what
# lets a subtree be rejected without being opened -- opening it to read its
# own bound would need the node twice, and `+` on a node is a reference count
# paid by every ray.
def Bvh.find(t: Bvh, near: Bool, best: Cand, +ro: V.V3, +rd: V.V3) -> Cand:
  match t:
    case BEmpty{}:
      best
    case BItems{items}:
      match near:
        case False{}:
          best
        case True{}:
          Balls.find(items, best, ro, rd)
    case BPair{lc, lr, l, rc, rr, r}:
      match near:
        case False{}:
          best
        case True{}:
          Bvh.find(r, Sph.blocks(ro, rd, rc, rr),
            Bvh.find(l, Sph.blocks(ro, rd, lc, lr), best, ro, rd), ro, rd)

def Cloud.find(c: Cloud, +ro: V.V3, +rd: V.V3) -> Cand:
  match c:
    case Cloud{ctr, rad, root}:
      Bvh.find(root, Sph.blocks(ro, rd, ctr, rad), Void{}, ro, rd)

def Scene.find(+balls: Cloud, +ro: V.V3, +rd: V.V3) -> Cand:
  h0 = Plane.cand(ro, rd, V.V3{0.46, 0.46, 0.50}, 0.16)
  h1 = Sph.cand(ro, rd, Scene.c1(), Scene.r1(), V.V3{0.95, 0.96, 0.98}, 0.88)
  h2 = Sph.cand(ro, rd, Scene.c2(), Scene.r2(), V.V3{0.88, 0.22, 0.18}, 0.0)
  h3 = Sph.cand(ro, rd, Scene.c3(), Scene.r3(), V.V3{0.22, 0.40, 0.90}, 0.05)
  h4 = Sph.cand(ro, rd, Scene.c4(), Scene.r4(), V.V3{0.96, 0.74, 0.28}, 0.5)
  h5 = Sph.cand(ro, rd, Scene.c5(), Scene.r5(), V.V3{0.28, 0.74, 0.34}, 0.0)
  Cand.closer(Cand.closer(Cand.closer(h0, h1), Cloud.find(balls, ro, rd)),
    Cand.closer(Cand.closer(h2, h3), Cand.closer(h4, h5)))

# A second copy of `Scene.find`, for callers outside the render loop.
#
# `Scene.find` is inlined into the per-pixel path. Adding a single cold call
# site -- the shift-click spawner, which runs once per click -- was enough to
# make the compiler outline it instead, and every ray in every frame then paid
# for the call. Measured at 1080p with 8 balls: 62 ms a frame with this copy,
# 120 ms without it. Keep the two bodies identical; see NOTES-BEND.md.
def Scene.find.cold(+balls: Cloud, +ro: V.V3, +rd: V.V3) -> Cand:
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

def Balls.shadowed(bs: Blobs, hit: Bool, +ro: V.V3, +rd: V.V3) -> Bool:
  match bs hit:
    case BNil{} True{}:
      True{}
    case BNil{} False{}:
      False{}
    case BCons{b, tl} True{}:
      True{}
    case BCons{b, tl} False{}:
      Balls.shadowed(tl, Ball.blocks(b, ro, rd), ro, rd)

# The occlusion walk carries `done`, the answer so far, and hands the left
# subtree's result to the right one as its starting value. A right subtree
# whose `done` is already True returns immediately without being opened, so
# the walk still stops at the first blocker even though Bend is strict.
def Bvh.shadowed(t: Bvh, near: Bool, done: Bool, +ro: V.V3, +rd: V.V3) ->
  Bool:
  match t:
    case BEmpty{}:
      done
    case BItems{items}:
      match near done:
        case True{} False{}:
          Balls.shadowed(items, False{}, ro, rd)
        case True{} True{}:
          True{}
        case False{} True{}:
          True{}
        case False{} False{}:
          False{}
    case BPair{lc, lr, l, rc, rr, r}:
      match near done:
        case True{} False{}:
          Bvh.shadowed(r, Sph.blocks(ro, rd, rc, rr),
            Bvh.shadowed(l, Sph.blocks(ro, rd, lc, lr), False{}, ro, rd), ro,
            rd)
        case True{} True{}:
          True{}
        case False{} True{}:
          True{}
        case False{} False{}:
          False{}

def Cloud.shadowed(c: Cloud, +ro: V.V3, +rd: V.V3) -> Bool:
  match c:
    case Cloud{ctr, rad, root}:
      Bvh.shadowed(root, Sph.blocks(ro, rd, ctr, rad), False{}, ro, rd)

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
