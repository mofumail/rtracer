# Notes on Bend 2.0.5

Rough edges hit while writing this ray tracer, in the order they bit. Each is
written so it could be dropped into a GitHub issue. Versions: Bend 2.0.5,
clang 22.1.8, CUDA 13.4, Linux.

Everything here had a workaround; none of it blocked the project.

---

### 1. No negative numeric literals

`-2.2` is a parse error (`expected a name, observed '2'`), so a negative float
constant has to be written `F32.neg(2.2)`.

The natural-looking fallback is worse: `0.0 - 2.2` parses, but bare operators
belong to `Nat`, so it fails with `expected Nat, observed F32` somewhere else
in the expression — the error points at the enclosing call, not at the
literal. A scene file full of coordinates ends up reading
`V.V3{F32.neg(2.4), 0.6, 0.9}`.

Suggestion: accept `-` before a numeric literal, or at least mention the
`F32.neg` idiom in the guide's literal table.

---

### 2. A computed tuple cannot be destructured

```python
(o2, d2) = Trace.bounce(pos, nrm, rd)   # rejected
```

> a parameter or field scrutinee (a match cannot scrutinize a computed value:
> give it its own def)

The rule is documented for `match`, and the message is clear about the fix,
but it also applies to destructuring lets — which means **a function cannot
usefully return a tuple**. Every multi-value return either needs a helper def
that takes the pair as a parameter, or has to be split into one def per
component. I split `Trace.bounce` into `Trace.org` and `Trace.dir`, which
recompute nothing but do mean the shared setup is written twice.

Since the scrutinee here is a `Sigma` with one constructor, an irrefutable
destructuring let looks like it could be allowed without weakening the
termination or proof story.

---

### 3. `law ... where` changes the type of the binder in the law's own statement

The guide describes `for y: B where P(y)` as "y is then the pair `(y, P(y)
proof)`". That is accurate, but it applies inside the law's conclusion too, so
this does not check:

```python
law clamp_ok:
  for +v: U32
  for c: Cmp where {U32.cmp(v, 1780) == c : Cmp}
  {Cam.pitch_ok(Cam.pitch_clamp.go(c, v)) == True{} : Bool}
```

> expected: Cmp
> observed: Sigma<&1, &1, Cmp, c => {U32.cmp(v, 1780) == c : Cmp}>

`c` in the conclusion is the pair, not the `Cmp`, so the conclusion has to
project it back out. Writing the hypothesis as an ordinary parameter works and
reads better:

```python
  for c: Cmp
  for h: {U32.cmp(v, 1780) == c : Cmp}
```

Suggestion: either have `where` bind the plain value in the conclusion and
keep the proof separate, or show the `for h:` form in the guide, since it is
the one that composes.

---

### 4. A failed proof can print a term megabytes wide

Breaking `bounce_depth` on purpose (counting `2n+` per bounce instead of `1n+`)
produced a 31 KB single-line error: the expected and observed terms with every
def inlined, so the whole ray-sphere intersection appears several times inside
one `Nat.cmp`. The actual discrepancy is one `1n+` versus `2n+`.

```
- expected : {Cmp.is_le(Nat.cmp(1n+scene.Trace.depth(p, scene.Hit.closer(scene.Hit.closer(scene.Plane.hit(vec.V3.add(pos^2, vec.V3.scale(nrm^3, 0.001)), ...
```

Contrast the small cases, which are excellent — the colour-clamp break printed
exactly `expected Cmp.is_le(U32.cmp(n, 255)), observed True{}` with the
hypothesis in context.

Suggestion: elide subterms past a depth or width budget (`...`), or diff the
two terms and show only the first disagreement. As it stands, the useful
diagnostic is invisible precisely when the proof is over real code.

---

### 5. `$CUDA_HOME` works but is not documented

`bend guide` says a GPU build on Linux needs "CUDA 12 at `/usr/local/cuda`".
Two things are truer than that, and both are only visible by reading
`bend2/main.ts`:

* `CUDA_HOME` is honoured and takes priority (`process.env.CUDA_HOME ||
  "/usr/local/cuda"`), which is what distro packages need — Arch installs to
  `/opt/cuda` and never creates `/usr/local/cuda`.
* CUDA **13.4** built and ran the `!` kernels here with no trouble, so the
  "CUDA 12" in the guide reads as stricter than it is.

Suggestion: mention `CUDA_HOME` in the guide's tooling section, and relax the
version wording to "CUDA 12 or newer".

---

### 6. The window drops mouse-wheel events

X11 reports the scroll wheel as buttons 4 and 5, and Bend's event pump keeps
only buttons 1 to 3:

```c
} else if (ev.type == ButtonPress || ev.type == ButtonRelease) {
  u32 b = ev.xbutton.button;
  if (b >= 1 && b <= 3) {                 // 4 and 5 are the wheel
    window_push(win, 1, ..., b == 1 ? 0 : 4 - b, ...);
```

So a Bend program cannot see the wheel at all, and there is no `Event`
constructor for a scroll either. Verified with an event probe: left, right and
middle arrive as `Mouse(..., b0/b1/b2, ...)`, while `xdotool click 4` and
`click 5` produce nothing. `XSelectInput` already asks for `ButtonPressMask`,
so the events do reach the pump and are then discarded.

This one is a real functional gap rather than an ergonomic wrinkle — zoom on
the wheel is the default idiom for any 3D viewer. This project puts zoom on a
right-button drag instead.

Suggestion: pass buttons 4 and 5 through (they would fall out as buttons 3 and
-1 under the current `4 - b` mapping, so the mapping needs widening too), or
add a `Scroll{x, y, dx, dy}` event.

---

### 7. A 2K frame is dominated by Image allocation, not by user code

At 1920x1080 the frame is a depth-11 quadtree: 4.19M `Pix` nodes plus ~1.4M
`Qua` nodes, allocated and freed every frame. Replacing the whole ray tracer
with `Pix{(x + y : U32)}` — no intersections, no shading, no recursion — still
costs 22 ms/frame end to end, against 21-29 ms for the real renderer.

In other words the shading is roughly 5 ms and the tree is roughly 22 ms, so
tuning the tracer has almost no effect on the frame rate. This was worth
knowing before optimizing: the obvious wins (a cheap occlusion-only shadow
traversal, deferring the normal to the winning hit, an adaptive bounce cutoff)
together bought about 10% end to end, because they were aimed at the small
half of the budget.

Not obviously a bug, but the cost is invisible from the source: nothing in
`Qua{tl, tr, bl, br}` suggests it is the expensive part of a ray tracer.
Something in the guide about the per-node cost of `Image`, or a way to build a
frame without one node per pixel, would help. The GPU is hit hardest: bare
tree construction at 2048x2048 costs 26.5 ms on the GPU against 5.2 ms on 32
CPU threads, which is the reverse of the ratio for the arithmetic.

---

### 8. Smaller things

* **`String.is_eq` is missing.** Base has `is_eq` for `Nat`, `U32`, `F32`,
  `Bool` and `Cmp`, and the guide says the verbs recur across types, so its
  absence for `String` is a surprise.
* **Strict definition order, with no forward references.** Combined with the
  ban on mutual recursion, this means a file has to be written strictly
  bottom-up; a helper placed after its caller fails with
  `expected a defined name`. Fine once you know, but it interacts awkwardly
  with the "give it its own def" advice from item 2, since each new helper has
  to be hoisted above every use.
* **Affinity errors point at the def, not the use.** `observed: y (consumed
  more than once)` names the binder and the enclosing def, but the location
  shown is the `def` line rather than the second use, which in a long
  `match` arm means hunting for it.

---

### 9. Marking a freshly-computed Image `+` costs ~9x re-computing it

The viewer cached its rendered frame in the app state, so that a frame with no
camera change could be handed back instead of re-traced. `App`'s `view` must
return the state *and* the image, so the cached frame is used twice and has to
be `+`:

```python
case True{}:
  +new = R.Render.frame(cam)                      # used twice, below
  (St{cam, drag, mx, my, new, False{}, live}, new)
```

Measured at 1920x1080, dragging (so every frame is a fresh trace):

* with the cache: **206 ms/frame**
* without it, tracing every frame unconditionally: **22 ms/frame**

So the cache made the interactive case about 9x *slower* than not caching. An
idle frame, where the `+` falls on an Image that is already evaluated, stays
cheap (16.7 ms) — it is specifically duplicating a *freshly computed* Image
that is expensive, which is consistent with the duplication copying the
pending computation rather than a finished value. Re-tracing 4.19M pixels is
cheaper than `+` on the tree they live in.

This is a nasty one to find, because the cache is an obvious optimization,
the code reads as correct, and the cost shows up only under interaction. A
diagnostic for "this `+` duplicated a redex rather than a value" would have
saved hours.

---

### 10. Pruning an unbalanced quadtree is much worse than wasting the work

A 1920x1080 window means a 2048x2048 tree, so ~51% of the leaves are never
shown. Skipping any tile whose origin is past the visible rectangle — an O(1)
`Pix{0}` instead of a subtree — should halve the work. Measured:

* full tree, every leaf traced: **22 ms/frame**
* off-screen tiles pruned: **62 ms/frame**

Pruning is *three times slower* than doing the wasted work. This is the
fork-join scheduler behaving exactly as the guide warns — every task is handed
to a core once and never moved — but the size of the penalty is worth knowing:
an unbalanced split does not merely lose the speed-up, it costs far more than
the work it saves. Anything that prunes, early-exits or varies per-tile cost
needs to keep the split balanced or not bother.

---

### 11. Unexplained: the same frame costs ~4x less inside a window app

Rendering depth 10 (1024x1024) with `--gpu off --threads 1`:

* headless, `Img.count(10n, Render.at(10n, cam))` in a loop: **124 ms/frame**
* the same `Render.at` driven by `App.run` into a 1024x1024 window, timed
  across 20 frames with `IO.now`: **29 ms/frame**, and that figure *includes*
  the serial blit

Things ruled out:

* **Not laziness.** `Img.count` matches `Pix{c}` and never reads `c`, while
  `Img.sum` returns it; they cost 124 ms and 117 ms, so the colour is computed
  either way.
* **Not visibility.** At 1024x1024 with a depth-10 tree every leaf is on
  screen, so the blit demands all of them.
* **Not the camera.** Both use the same `Cam{450, 1005, 780}`.

So the same frame, the same thread count, ~4x apart depending on whether a
window is driving it. Either the headless loop is doing avoidable work (the
accumulator chain?), or `--threads 1` does not mean the same thing once the
event loop is running. Worth a look from someone who knows the scheduler.

---

### Not a bug: the GPU loses to 32 CPU cores here

Worth recording since it is counter-intuitive for a renderer. At 1024×1024
the headless trace takes 37.7 ms on 32 CPU threads and 51.0 ms on an RTX
4070 Ti, and the ratio holds across frame sizes. (In the windowed app the GPU
still wins overall, because the window's blit is serial on the CPU.) This is consistent with what the guide
says — divergent work stays faster on the CPU — and a ray tracer is divergent:
a ray that misses everything returns the sky immediately, while the lane next
to it runs three bounces with a shadow ray each. The quadtree split itself
parallelises fine (10.4× from 1 to 32 threads).
