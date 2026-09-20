# LAWS.bend -- the renderer's specification.
#
# Four properties the ray tracer must have, stated as open claims. PROOF.bend
# fills each one in; `bend PROOF.bend` fails while any is open or false.
#
# All four are deliberately about structure and integer bounds, never about
# float precision: Bend's F32 operations are opaque primitives (`law F32.add`
# and friends have no computational content), so nothing can be proven about
# a float. That is why the camera's pitch and the colour channels are held as
# integers and clamped there -- it moves the interesting bounds into a domain
# where they can actually be established.

import Base
import ./vec.bend as V
import ./scene.bend as S
import ./render.bend as R

# The laws hold for any set of balls the user has dropped in, not just for the
# fixed scene: `frame_pixels` and `bounce_depth` both quantify over the list.
#
# 1. The output always has exactly width * height pixels.
#
# A frame is a quadtree `d` levels deep over a 2^d square, so width * height
# is 4^d. `Img.count` only counts a tree that is exactly `d` levels deep, so
# this says the renderer never stops early and never splits too far: every
# one of the 4^d pixels is there.
law frame_pixels:
  for +d: Nat
  for +c: R.Cam
  for +balls: S.Blobs
  {R.Img.count(d, R.Render.at(d, c, balls)) == Nat.pow(4n, d) : Nat}

# 2. Every colour channel is clamped to 0-255.
#
# A channel is a U32, so the lower bound holds by construction; this is the
# upper one, for any float whatsoever -- including the infinities and NaNs a
# degenerate ray could produce.
law channel_bounded:
  for +v: F32
  {U32.is_le(R.Color.byte(v), R.Color.MAX()) == True{} : Bool}

# 3. Pitch is always clamped between -89 and +89 degrees.
#
# Pitch is stored in tenths of a degree, offset so that 0 is -89.0 and 1780 is
# +89.0. `Cam.pitch_step` is the only thing in the app that changes it, so
# this says that after any drag at all -- any distance, either direction --
# the camera is still inside the legal range and cannot flip over.
law pitch_in_range:
  for +v: U32
  for +dn: U32
  for up: Bool
  {R.Cam.pitch_ok(R.Cam.pitch_step(v, dn, up)) == True{} : Bool}

# 4. Reflection recursion never exceeds a fixed max depth.
#
# `Trace.depth` counts the bounces `Trace` takes on the same inputs, branching
# the same way and sharing its ray-generation defs, so this bounds the renderer
# rather than a separate copy of it: from any hit, any ray, and any starting
# weight, the tracer returns within MAX_DEPTH bounces.
#
# The adaptive cutoff can only end a chain sooner, never later, so this still
# holds now that a bounce is skipped once its contribution gets too small.
law bounce_depth:
  for go: Bool
  for +c: S.Cand
  for +ro: V.V3
  for +rd: V.V3
  for +w: F32
  for +balls: S.Blobs
  {Nat.is_le(S.Trace.depth(S.Scene.MAX_DEPTH(), go, c, ro, rd, w, balls),
    S.Scene.MAX_DEPTH()) == True{} : Bool}
