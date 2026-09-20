# Phys: gravity and collision for the balls the user drops in.
#
# A ball falls, lands on the floor or on whatever is under it, and comes to
# rest. Collisions are resolved one ball at a time against everything else
# treated as immovable: it is not momentum-conserving, but a dropped ball
# settling onto a static sphere or onto another ball looks right, and it keeps
# each ball's update independent of the others' updates, which is what lets
# the list be walked once per frame instead of iterated to a fixed point.
#
# As everywhere else in this project, a test on a float has to be handed to a
# def as a Bool, because Bend only matches parameters.

import Base
import ./vec.bend as V
import ./scene.bend as S

def Phys.DT() -> F32:
  0.016

def Phys.G() -> F32:
  14.0

# How much speed survives a bounce, and the drag applied on contact so a ball
# eventually settles instead of jittering forever.
def Phys.REST() -> F32:
  0.36

def Phys.DAMP() -> F32:
  0.82

# A contact slower than this does not bounce. It must stay above one frame of
# gravity (G * DT), or a ball in free fall would be treated as resting.
def Phys.SLEEP() -> F32:
  0.35

def Phys.MAX() -> Nat:
  14n

# -- One contact --------------------------------------------------------------

# A slow contact just loses its normal component and slides; a fast one
# bounces. Without that split a resting ball gets gravity added, reflected,
# and re-added every frame, and jitters forever.
def Phys.bounce.go(soft: Bool, vt: V.V3, n: V.V3, +vn: F32) -> V.V3:
  match soft:
    case True{}:
      V.V3.scale(vt, Phys.DAMP())
    case False{}:
      V.V3.scale(V.V3.sub(vt, V.V3.scale(n, (vn * Phys.REST() : F32))),
        Phys.DAMP())

# Reflect the velocity about the contact normal, but only if the ball is
# actually moving into the surface.
def Phys.bounce(into: Bool, vel: V.V3, +n: V.V3, +vn: F32) -> V.V3:
  match into:
    case True{}:
      Phys.bounce.go(F32.is_lt(F32.abs(vn), Phys.SLEEP()),
        V.V3.sub(vel, V.V3.scale(n, vn)), n, vn)
    case False{}:
      vel

# `dist` is the centre distance and `sum` the summed radii, so the ball is
# lifted back out to exactly touching.
def Phys.contact(hit: Bool, b: S.Ball, +ctr: V.V3, +sum: F32, +dist: F32) ->
  S.Ball:
  match hit:
    case True{}:
      match b:
        case S.Ball{id, +pos, +vel, rad, alb, refl}:
          +n = V.V3.scale(V.V3.sub(pos, ctr), (1.0 / dist : F32))
          +vn = V.V3.dot(vel, n)
          S.Ball{id, V.V3.add(ctr, V.V3.scale(n, sum)),
            Phys.bounce(F32.is_lt(vn, 0.0), vel, n, vn), rad, alb, refl}
    case False{}:
      b

# Collide a ball with an immovable sphere.
def Phys.vs_sphere(b: S.Ball, +ctr: V.V3, +rad: F32) -> S.Ball:
  match b:
    case S.Ball{id, +pos, vel, +brad, alb, refl}:
      +sum = (brad + rad : F32)
      # A zero distance would divide by zero when building the normal, so the
      # two centres are never allowed to coincide exactly.
      +dist = F32.max(V.V3.len(V.V3.sub(pos, ctr)), 0.00001)
      Phys.contact(F32.is_lt(dist, sum),
        S.Ball{id, pos, vel, brad, alb, refl}, ctr, sum, dist)

def Phys.vs_ball(b: S.Ball, o: S.Ball) -> S.Ball:
  match o:
    case S.Ball{oid, opos, ovel, orad, oalb, orefl}:
      Phys.vs_sphere(b, opos, orad)

# Skips the ball's collision with itself.
def Phys.vs_other(same: Bool, b: S.Ball, o: S.Ball) -> S.Ball:
  match same:
    case True{}:
      b
    case False{}:
      Phys.vs_ball(b, o)

def Phys.id(b: S.Ball) -> U32:
  match b:
    case S.Ball{id, pos, vel, rad, alb, refl}:
      id

# The list comes first: Bend reads a recursive call's arguments left to right
# and wants the shrinking one before anything that changes.
def Phys.vs_list(others: S.Blobs, b: S.Ball, +me: U32) -> S.Ball:
  match others:
    case S.BNil{}:
      b
    case S.BCons{+o, tl}:
      Phys.vs_list(tl, Phys.vs_other(U32.is_eq(me, Phys.id(o)), b, o), me)

# -- The floor ----------------------------------------------------------------

def Phys.floor.go(under: Bool, id: U32, pos: V.V3, vel: V.V3, +rad: F32,
  alb: V.V3, refl: F32) -> S.Ball:
  match under:
    case False{}:
      S.Ball{id, pos, vel, rad, alb, refl}
    case True{}:
      match pos vel:
        case V.V3{px, py, pz} V.V3{vx, vy, vz}:
          +vy = vy
          S.Ball{id, V.V3{px, rad, pz},
            Phys.bounce(F32.is_lt(vy, 0.0), V.V3{vx, vy, vz},
              V.V3{0.0, 1.0, 0.0}, vy), rad, alb, refl}

def Phys.floor(b: S.Ball) -> S.Ball:
  match b:
    case S.Ball{id, pos, vel, +rad, alb, refl}:
      match pos:
        case V.V3{px, +py, pz}:
          Phys.floor.go(F32.is_lt(py, rad), id, V.V3{px, py, pz}, vel, rad,
            alb, refl)

# -- One ball, one frame ------------------------------------------------------

# Gravity, then integrate.
def Phys.fall(b: S.Ball) -> S.Ball:
  match b:
    case S.Ball{id, pos, vel, rad, alb, refl}:
      +nv = V.V3.add(vel,
        V.V3{0.0, F32.neg((Phys.G() * Phys.DT() : F32)), 0.0})
      S.Ball{id, V.V3.add(pos, V.V3.scale(nv, Phys.DT())), nv, rad, alb, refl}

# The five fixed spheres, then the floor, then every other ball.
def Phys.statics(b: S.Ball) -> S.Ball:
  Phys.vs_sphere(
    Phys.vs_sphere(
      Phys.vs_sphere(
        Phys.vs_sphere(
          Phys.vs_sphere(b, S.Scene.c1(), S.Scene.r1()),
          S.Scene.c2(), S.Scene.r2()),
        S.Scene.c3(), S.Scene.r3()),
      S.Scene.c4(), S.Scene.r4()),
    S.Scene.c5(), S.Scene.r5())

def Phys.one(b: S.Ball, +all: S.Blobs) -> S.Ball:
  +moved = Phys.floor(Phys.statics(Phys.fall(b)))
  Phys.vs_list(all, moved, Phys.id(moved))

# -- The whole list -----------------------------------------------------------

# `all` is passed through unchanged and `rest` shrinks, which is the order
# Bend's termination check reads arguments in.
def Phys.go(+all: S.Blobs, rest: S.Blobs) -> S.Blobs:
  match rest:
    case S.BNil{}:
      S.BNil{}
    case S.BCons{b, tl}:
      S.BCons{Phys.one(b, all), Phys.go(all, tl)}

def Phys.step(+bs: S.Blobs) -> S.Blobs:
  Phys.go(bs, bs)

# Keeps the newest `n` balls, so dropping more than the cap quietly retires
# the oldest instead of letting the per-ray cost grow without bound.
def Phys.take(n: Nat, bs: S.Blobs) -> S.Blobs:
  match n:
    case 0n:
      S.BNil{}
    case 1n+p:
      match bs:
        case S.BNil{}:
          S.BNil{}
        case S.BCons{b, tl}:
          S.BCons{b, Phys.take(p, tl)}

# -- The bounding volume ------------------------------------------------------

# Rebuilt once per frame and handed to the renderer, where every ray tests it
# before touching the list.
def Phys.centre.fin(none: Bool, acc: V.V3, +n: F32) -> V.V3:
  match none:
    case True{}:
      V.V3{0.0, 0.0, 0.0}
    case False{}:
      V.V3.scale(acc, (1.0 / n : F32))

def Phys.centre.go(bs: S.Blobs, acc: V.V3, +n: F32) -> V.V3:
  match bs:
    case S.BNil{}:
      Phys.centre.fin(F32.is_lt(n, 0.5), acc, n)
    case S.BCons{b, tl}:
      match b:
        case S.Ball{id, pos, vel, rad, alb, refl}:
          Phys.centre.go(tl, V.V3.add(acc, pos), (n + 1.0 : F32))

def Phys.reach(bs: S.Blobs, +ctr: V.V3, +best: F32) -> F32:
  match bs:
    case S.BNil{}:
      best
    case S.BCons{b, tl}:
      match b:
        case S.Ball{id, pos, vel, rad, alb, refl}:
          Phys.reach(tl, ctr,
            F32.max(best, (V.V3.len(V.V3.sub(pos, ctr)) + rad : F32)))

# An empty cloud gets a zero radius, so the bound test rejects immediately.
# The same bound, but with the balls left as a flat list instead of a tree.
#
# This is for one-off queries outside the render loop -- the shift-click
# spawner casts a single ray. It exists so that `Bvh.build` is not reachable
# from the app's tick at all: a cold caller of a big recursive routine
# de-optimises the hot path it shares code with, which cost 21 ms a frame
# against 79 ms when the spawner built a tree. See NOTES-BEND.md.
def Phys.flat(+bs: S.Blobs) -> S.Cloud:
  +c = Phys.centre.go(bs, V.V3{0.0, 0.0, 0.0}, 0.0)
  S.Cloud{c, Phys.reach(bs, c, 0.0), S.BItems{bs}}

def Phys.cloud(+bs: S.Blobs) -> S.Cloud:
  +c = Phys.centre.go(bs, V.V3{0.0, 0.0, 0.0}, 0.0)
  S.Cloud{c, Phys.reach(bs, c, 0.0), S.Bvh.of(bs)}
