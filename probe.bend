# The same viewer as main.bend, but it stamps stdout with the wall clock on
# every frame. `./run.sh probe` turns that into a live frames-per-second
# readout, so a slow frame rate can be measured rather than guessed at.
#
# It reuses main.bend's view and tick, so it is the real app being measured,
# not a copy that might drift from it.

import Base
import ./render.bend as R
import ./main.bend as M

def Probe.tick(evs: List<Event>, s: M.St) -> IO(Maybe<M.St>):
  do IO<Maybe<M.St>>:
    t : Nat <- IO.now()
    IO.print(Nat.show(t))
    M.Tick(evs, s)

def main() -> IO(Unit):
  App.run(~M.St, ~App{M.View, Probe.tick}, "Bend Ray Tracer",
    R.Render.WIDTH(), R.Render.HEIGHT(), M.St.init())
