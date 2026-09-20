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

### 6. Smaller things

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

### Not a bug: the GPU loses to 32 CPU cores here

Worth recording since it is counter-intuitive for a renderer. At 1024×1024
this scene takes 10.8 ms on 32 CPU threads and 19.2 ms on an RTX 4070 Ti, and
the ratio holds across frame sizes. This is consistent with what the guide
says — divergent work stays faster on the CPU — and a ray tracer is divergent:
a ray that misses everything returns the sky immediately, while the lane next
to it runs three bounces with a shadow ray each. The quadtree split itself
parallelises fine (10.4× from 1 to 32 threads).
