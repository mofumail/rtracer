# A headless timing harness: renders a fixed set of frames and reports the
# average frame time, so the same binary can be measured under
# `--gpu off --threads 1`, `--gpu off`, and the GPU default.
#
# This measures tracing only. It walks the finished frame with `Img.sum` so
# that nothing can be skipped, which is work the real app does not do -- the
# window blit reads the tree instead. Treat these as a comparison between
# backends, not as frame times; README has the end-to-end figures.

import Base
import ./render.bend as R

# `Img.sum` walks the whole frame, so nothing can be skipped.
def Bench.one(+d: Nat, yaw: U32) -> U32:
  R.Img.sum(d, R.Render.at(d, R.Cam{yaw, 1005, 780}))

def Bench.loop(n: Nat, +d: Nat, +yaw: U32, acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+p:
      Bench.loop(p, d, (yaw + 137 : U32), (acc + Bench.one(d, yaw) : U32))

# Frame times are reported in microseconds, since a small frame on 32 cores
# lands well under the 1 ms resolution of IO.now.
def Bench.report(name: String, +n: Nat, t0: Nat, t1: Nat, sum: U32) ->
  IO(Unit):
  +us = Nat.mul(Nat.sub(t1, t0), 1000n)
  IO.print(name ++ "  " ++ Nat.show(Nat.div(us, n)) ++ " us/frame  (" ++
    Nat.show(Nat.div(us, 1000n)) ++ " ms over " ++ Nat.show(n) ++
    " frames, checksum " ++ U32.show(sum) ++ ")")

def Bench.run(name: String, +d: Nat, +n: Nat) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    sum : U32 <- IO.pure(U32, Bench.loop(n, d, 0, 0))
    t1 : Nat <- IO.now()
    Bench.report(name, n, t0, t1, sum)

def main() -> IO(Unit):
  do IO<Unit>:
    Bench.run("512x512          ", 9n, 60n)
    Bench.run("1024x1024        ", 10n, 20n)
    Bench.run("2048x2048  (2K)  ", R.Render.FULL_D(), 10n)
