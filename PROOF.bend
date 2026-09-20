# PROOF.bend -- proofs for every law in LAWS.bend.
#
# `bend PROOF.bend` is the gate: it prints "All terms check." only when all
# four laws hold. The helper lemmas below are stated and proven here; LAWS.bend
# holds only the four claims themselves.

import Base
import ./vec.bend as V
import ./scene.bend as S
import ./render.bend as R
import ./LAWS.bend as Laws

# -- Arithmetic lemmas --------------------------------------------------------

law add_zero:
  for x: Nat
  {Nat.add(x, 0n) == x : Nat}

def add_zero(x):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %add_zero(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}
      {==}

# `Nat.mul(4n, k)` unfolds to k + (k + (k + (k + 0))); the sum of four k's is
# the same thing once the trailing zero is removed.
law four_k:
  for +k: Nat
  {Nat.add(k, Nat.add(k, Nat.add(k, k))) == Nat.mul(4n, k) : Nat}

def four_k(k):
  %add_zero(k) :
    {Nat.add(k, Nat.add(k, Nat.add(k, _))) == Nat.mul(4n, k) : Nat}
  {==}

# Four values each equal to k sum to 4k. Keeping this separate is what makes
# the quadtree induction readable: inside here a, b, c and e are plain
# variables, so the rewrite annotations stay short.
law add4:
  for -a: Nat
  for -b: Nat
  for -c: Nat
  for -e: Nat
  for +k: Nat
  for pa: {a == k : Nat}
  for pb: {b == k : Nat}
  for pc: {c == k : Nat}
  for pe: {e == k : Nat}
  {Nat.add(a, Nat.add(b, Nat.add(c, e))) == Nat.mul(4n, k) : Nat}

def add4(a, b, c, e, k, pa, pb, pc, pe):
  %Equal.sym(Nat, a, k, pa) :
    {Nat.add(_, Nat.add(b, Nat.add(c, e))) == Nat.mul(4n, k) : Nat}
  %Equal.sym(Nat, b, k, pb) :
    {Nat.add(k, Nat.add(_, Nat.add(c, e))) == Nat.mul(4n, k) : Nat}
  %Equal.sym(Nat, c, k, pc) :
    {Nat.add(k, Nat.add(k, Nat.add(_, e))) == Nat.mul(4n, k) : Nat}
  %Equal.sym(Nat, e, k, pe) :
    {Nat.add(k, Nat.add(k, Nat.add(k, _))) == Nat.mul(4n, k) : Nat}
  four_k(k)

# -- Law 1: a frame has exactly 4^d pixels ------------------------------------

# Induction on the split depth. The base case is a single Pix, which counts as
# one pixel whatever colour it holds -- the proof never looks at the shading,
# which is what keeps it independent of the float math.
law tile_pixels:
  for +d: Nat
  for +step: U32
  for +x: U32
  for +y: U32
  for +bs: R.Basis
  {R.Img.count(d, R.Render.tile(d, step, x, y, bs)) == Nat.pow(4n, d) : Nat}

def tile_pixels(d, step, x, y, bs):
  match d:
    case 0n:
      {==}
    case 1n+p:
      +h = U32.shr(step)
      add4(
        R.Img.count(p, R.Render.tile(p, h, x, y, bs)),
        R.Img.count(p, R.Render.tile(p, h, (x + h : U32), y, bs)),
        R.Img.count(p, R.Render.tile(p, h, x, (y + h : U32), bs)),
        R.Img.count(p, R.Render.tile(p, h, (x + h : U32), (y + h : U32), bs)),
        Nat.pow(4n, p),
        tile_pixels(p, h, x, y, bs),
        tile_pixels(p, h, (x + h : U32), y, bs),
        tile_pixels(p, h, x, (y + h : U32), bs),
        tile_pixels(p, h, (x + h : U32), (y + h : U32), bs))

def Laws.frame_pixels(d, c):
  tile_pixels(d, R.Render.size(d), 0, 0,
    R.Basis.of(c, U32.to_f32(R.Render.WIDTH()),
      U32.to_f32(R.Render.HEIGHT())))

# -- Law 2: colour channels are bounded ---------------------------------------

# `Color.cap` branches on `U32.cmp(n, 255)`. The branch alone does not tell the
# checker which way the comparison went, so the lemma carries the comparison's
# result as an equation and case-splits on that instead.
law cap_go_ok:
  for +n: U32
  for c: Cmp
  for h: {U32.cmp(n, R.Color.MAX()) == c : Cmp}
  {U32.is_le(R.Color.cap.go(c, n), R.Color.MAX()) == True{} : Bool}

def cap_go_ok(n, c, h):
  match c:
    case LT{}:
      %Equal.sym(Cmp, U32.cmp(n, R.Color.MAX()), LT{}, h) :
        {Cmp.is_le(_) == True{} : Bool}
      {==}
    case EQ{}:
      %Equal.sym(Cmp, U32.cmp(n, R.Color.MAX()), EQ{}, h) :
        {Cmp.is_le(_) == True{} : Bool}
      {==}
    case GT{}:
      {==}

law cap_ok:
  for +n: U32
  {U32.is_le(R.Color.cap(n), R.Color.MAX()) == True{} : Bool}

def cap_ok(n):
  cap_go_ok(n, U32.cmp(n, R.Color.MAX()), {==})

def Laws.channel_bounded(v):
  cap_ok(F32.to_u32((F32.sqrt(F32.clamp(v, 0.0, 1.0)) * 255.0 + 0.5 : F32)))

# -- Law 3: pitch stays in range ----------------------------------------------

law pitch_go_ok:
  for +v: U32
  for c: Cmp
  for h: {U32.cmp(v, R.Cam.PITCH_MAX()) == c : Cmp}
  {R.Cam.pitch_ok(R.Cam.pitch_clamp.go(c, v)) == True{} : Bool}

def pitch_go_ok(v, c, h):
  match c:
    case LT{}:
      %Equal.sym(Cmp, U32.cmp(v, R.Cam.PITCH_MAX()), LT{}, h) :
        {Cmp.is_le(_) == True{} : Bool}
      {==}
    case EQ{}:
      %Equal.sym(Cmp, U32.cmp(v, R.Cam.PITCH_MAX()), EQ{}, h) :
        {Cmp.is_le(_) == True{} : Bool}
      {==}
    case GT{}:
      {==}

law pitch_clamp_ok:
  for +v: U32
  {R.Cam.pitch_ok(R.Cam.pitch_clamp(v)) == True{} : Bool}

def pitch_clamp_ok(v):
  pitch_go_ok(v, U32.cmp(v, R.Cam.PITCH_MAX()), {==})

# Whatever the drag did, the result went through the clamp, so the bound holds
# without needing to know anything about the raw value.
def Laws.pitch_in_range(v, dn, up):
  pitch_clamp_ok(R.Cam.step.raw(up, v, dn))

# -- Law 4: bounded reflection depth ------------------------------------------

# Induction on the bounce budget. In the recursive case the goal reduces to
# `Nat.is_le(1n+X, 1n+d)`, which is `Nat.is_le(X, d)` -- exactly the induction
# hypothesis, so the proof is the recursive call itself.
law depth_le:
  for +d: Nat
  for go: Bool
  for +c: S.Cand
  for +ro: V.V3
  for +rd: V.V3
  for +w: F32
  {Nat.is_le(S.Trace.depth(d, go, c, ro, rd, w), d) == True{} : Bool}

def depth_le(d, go, c, ro, rd, w):
  match d:
    case 0n:
      {==}
    case 1n+p:
      match go:
        case False{}:
          {==}
        case True{}:
          match c:
            case S.Void{}:
              {==}
            case S.Cand{+t, ctr, alb, +refl, flat}:
              +pos = V.V3.add(ro, V.V3.scale(rd, t))
              +nrm = S.Cand.nrm(flat, pos, ctr)
              +ro2 = S.Trace.org(pos, nrm)
              +rd2 = S.Trace.dir(rd, nrm)
              +c2 = S.Scene.find(ro2, rd2)
              +w2 = (w * refl : F32)
              depth_le(p,
                F32.is_gt((w2 * S.Cand.refl(c2) : F32), S.Scene.MIN_W()), c2,
                ro2, rd2, w2)

def Laws.bounce_depth(go, c, ro, rd, w):
  depth_le(S.Scene.MAX_DEPTH(), go, c, ro, rd, w)
