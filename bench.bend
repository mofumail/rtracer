# A headless timing harness: renders a fixed set of frames and reports the
# average frame time, so the same binary can be measured under
# `--gpu off --threads 1`, `--gpu off`, and the GPU default.
#
# This measures tracing only. It walks the finished frame with `Img.sum` so
# that nothing can be skipped, which is work the real app does not do -- the
# window blit reads the tree instead. Treat these as a comparison between
# backends, not as frame times; README has the end-to-end figures.

import Base
import ./vec.bend as V
import ./scene.bend as S
import ./phys.bend as P
import ./render.bend as R

# A deterministic spread of balls across the visible floor. They are spread
# rather than clustered on purpose: a cluster sits inside the cloud's bounding
# sphere, so most rays miss it and the traversal never runs. Spreading them is
# the case that actually exercises the ball code.
def Mk.pos(+k: U32) -> V.V3:
  V.V3{(U32.to_f32((k * 37 % 97 : U32)) * 0.062 - 3.0 : F32), 0.34,
    (U32.to_f32((k * 53 % 89 : U32)) * 0.058 - 2.6 : F32)}

def Mk.alb(+k: U32) -> V.V3:
  V.V3{(U32.to_f32((k * 17 % 100 : U32)) * 0.01 : F32),
    (U32.to_f32((k * 41 % 100 : U32)) * 0.01 : F32),
    (U32.to_f32((k * 73 % 100 : U32)) * 0.01 : F32)}

def Mk.list(n: Nat, +k: U32, acc: S.Blobs) -> S.Blobs:
  match n:
    case 0n:
      acc
    case 1n+p:
      Mk.list(p, (k + 1 : U32),
        S.BCons{S.Ball{k, Mk.pos(k), V.V3{0.0, 0.0, 0.0}, 0.34, Mk.alb(k),
          0.1}, acc})

# `Img.sum` walks the whole frame, so nothing can be skipped.
# Benchmarks the fixed scene with no dropped balls.
def Bench.one(+d: Nat, yaw: U32, +balls: S.Cloud) -> U32:
  R.Img.sum(d, R.Render.at(d, R.Cam{yaw, 1005, 780}, balls))

def Bench.loop(n: Nat, +d: Nat, +yaw: U32, acc: U32, +balls: S.Cloud) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      Bench.loop(p, d, (yaw + 137 : U32),
        (acc + Bench.one(d, yaw, balls) : U32), balls)

# Frame times are reported in microseconds, since a small frame on 32 cores
# lands well under the 1 ms resolution of IO.now.
def Bench.report(name: String, +n: Nat, t0: Nat, t1: Nat, sum: U32) ->
  IO(Unit):
  +us = Nat.mul(Nat.sub(t1, t0), 1000n)
  IO.print(name ++ "  " ++ Nat.show(Nat.div(us, n)) ++ " us/frame  (" ++
    Nat.show(Nat.div(us, 1000n)) ++ " ms over " ++ Nat.show(n) ++
    " frames, checksum " ++ U32.show(sum) ++ ")")

def Bench.run(name: String, +d: Nat, +n: Nat, nb: Nat) -> IO(Unit):
  do IO<Unit>:
    balls : S.Cloud = P.Phys.cloud(Mk.list(nb, 1, S.BNil{}))
    t0 : Nat <- IO.now()
    sum : U32 <- IO.pure(U32, Bench.loop(n, d, 0, 0, balls))
    t1 : Nat <- IO.now()
    Bench.report(name, n, t0, t1, sum)

def main() -> IO(Unit):
  do IO<Unit>:
    Bench.run("512x512            ", 9n, 60n, 0n)
    Bench.run("1024x1024          ", 10n, 20n, 0n)
    Bench.run("2048x2048  (2K)    ", R.Render.FULL_D(), 10n, 0n)
    Bench.run("2K with   8 balls  ", R.Render.FULL_D(), 6n, 8n)
    Bench.run("2K with  32 balls  ", R.Render.FULL_D(), 6n, 32n)
