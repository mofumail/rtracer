# Bend Ray Tracer

An interactive ray tracer written entirely in [Bend](https://bend-lang.com).
The renderer, the window, the input handling and the proofs are all Bend —
there is no C, no CUDA, no Metal and no Python viewer.

Drag to orbit the camera. Every frame is traced at full 1920×1080 — the
resolution never drops while you move.

![the scene](docs/scene.png)

## Run it

```sh
./run.sh
```

That checks the toolchain, proves the four laws, builds the binaries and opens
the viewer. Other entry points:

| command | what it does |
| --- | --- |
| `./run.sh doctor` | report the toolchain and stop |
| `./run.sh proof` | run the proof gate (`bend PROOF.bend`) |
| `./run.sh build` | build `./rtracer` and `./bench` |
| `./run.sh bench` | time the renderer on 1 core, all cores, and the GPU |

**Controls** — left-drag to orbit · **right-drag up/down to zoom** · `Up`/`Down`
keys also zoom · `Esc` or the close box to quit.

> Zoom is on the right button rather than the wheel because **Bend 2.0.5 cannot
> see the wheel at all**: X11 reports it as buttons 4 and 5, and Bend's event
> pump keeps only buttons 1–3, so the events are discarded before any program
> sees them. See `NOTES-BEND.md` §6.

### Requirements

* Bend 2.0.5
* clang 19 or newer (19+ is what the `!` GPU calls need)
* For the GPU: CUDA on Linux, or Metal on macOS. `bend` looks in `$CUDA_HOME`
  and then `/usr/local/cuda`; `run.sh` finds a distro install (such as Arch's
  `/opt/cuda`) and exports `CUDA_HOME` for you.
* `libx11-dev` for the window.

Without a GPU everything still builds and runs — Bend executes `!` calls in
parallel on the CPU instead.

## The scene

A ground plane and five spheres under one directional light with hard shadows:
a mirror (0.88 reflective), a glossy gold sphere (0.5), a faintly reflective
blue one, and matte red and green ones. The floor is 0.16 reflective, which is
what gives the soft doubling under each sphere. Reflections recurse to a fixed
depth of 3.

No textures, no path tracing and no BVH — the scene is six objects tested
exhaustively per ray.

## How it is parallelised

Bend's `Image` is a quadtree: `Pix{colour}` paints a square and
`Qua{tl,tr,bl,br}` splits one in four. That is exactly the recursive split the
renderer wants, so `Render.tile` divides the frame into quadrants down to
single pixels and issues the four children as one parallel call:

```python
tl tr bl br = Render.tile(p, h, x, y, bs)
  Render.tile(p, h, (x + h : U32), y, bs)
  Render.tile(p, h, x, (y + h : U32), bs)
  Render.tile(p, h, (x + h : U32), (y + h : U32), bs)
```

The split is balanced by construction — every quadrant is the same size and
every leaf costs one primary ray — which is what Bend's fork-join scheduler
needs, since it hands each task to a core once and never moves it.

`Render.at` issues the whole tree with `Render.tile!(...)`, and the `!` sends
that call and every parallel call inside it to the GPU. Window handling and
input stay on the CPU, in `main.bend`.

Two details worth knowing:

* **The tree is square and power-of-two.** The window picks `k` with
  `2^k ≥ max(w,h)` and indexes the quadtree by the bits of x and y. For
  1920×1080 that is `k = 11`, so the frame is a 2048×2048 tree whose top-left
  corner is shown. The rays are aimed at the *visible* rectangle rather than
  at the square, so the picture stays centred and correctly proportioned; the
  extra columns and rows are simply traced and never looked at.
* **The ~50% waste is not fixable by pruning.** Skipping the off-screen
  quadrants would halve the rays, but it unbalances the split, and Bend's
  scheduler hands every task to a core once and never moves it — the idle
  lanes give the saving straight back.

The frame is cached in the app state and only re-rendered when an event moves
the camera; `App.run` calls `view` at 60 Hz, and re-tracing an unchanged scene
every frame would keep the GPU busy for nothing.

### Why the GPU, when the CPU traces rays faster

The window's own blit walks the tree once per screen pixel. That walk is a
**serial** loop on the CPU and a CUDA kernel on the GPU, which changes which
lane wins end to end:

| | trace | blit | total |
| --- | ---: | ---: | ---: |
| GPU | slower | ~free | **best** |
| CPU, 32 threads | faster | ~33 ms at 2K | worse |

Rendering on the CPU *with* the GPU enabled is worse than either, because the
corpus then lives in managed memory and every CPU thread pays for it — measured
at 38 ms against 26 ms for the same work with `--gpu off`.

## Benchmarks

**What you actually feel** — time per frame in the running app at 1920×1080,
full resolution, camera moving every frame (so nothing is served from cache):

| backend | ms/frame | |
| --- | ---: | --- |
| GPU (default) | **17** | ~59 fps — what ships |
| CPU, 32 threads, `--gpu off` | 44 | ~23 fps |
| CPU, 1 thread, `--gpu off --threads 1` | 74 | ~14 fps |

The GPU wins end to end even though the CPU traces rays faster, because the
window's blit is a serial loop on the CPU and a CUDA kernel on the GPU. See
*Why the GPU* above.

**Where the time goes.** Replacing the entire ray tracer with
`Pix{(x + y : U32)}` — no intersections, no shading, no recursion — still costs
**22 ms/frame**. At 2K the frame is a depth-11 quadtree: 4.19M `Pix` nodes plus
~1.4M `Qua` nodes built and freed every frame, and that allocation, not the
shading, is the budget. Tuning the tracer further would be wasted effort.

That is also why the tracer rewrite (occlusion-only shadow rays, deferring the
normal to the winning hit, an adaptive bounce cutoff) bought only ~10% end to
end: it was aimed at the small half of the budget. It is still better code, and
it is what makes the adaptive-depth law interesting.

**Backend comparison, headless** — `./run.sh bench` traces frames with no
window and walks each one with `Img.sum` so nothing can be skipped:

| frame | 1 thread | 32 threads | GPU |
| --- | ---: | ---: | ---: |
| 512×512 | 22 816 | **2 333** | 3 883 |
| 1024×1024 | 115 050 | **10 750** | 15 400 |
| 2048×2048 | 459 000 | **37 700** | 51 000 |

(µs/frame. All three backends produce identical checksums, which is a decent
end-to-end check that the CPU and GPU lanes agree.)

These two tables are measured differently and should not be compared with each
other: the headless figures include a full extra `Img.sum` traversal that the
app never does. They disagree by more than that pass alone accounts for — about
4× at one thread — which I have not been able to explain; `NOTES-BEND.md` §9
records it rather than guessing.

## The laws

`LAWS.bend` states four properties and `PROOF.bend` proves them.
`bend PROOF.bend` (or `./run.sh proof`) is the gate — it prints
`All terms check.` only when all four hold.

| law | what it says |
| --- | --- |
| `frame_pixels` | a frame rendered at depth `d` has exactly `4^d` pixels — `Img.count` only counts a tree exactly `d` levels deep, so the renderer never stops early or splits too far |
| `channel_bounded` | every colour channel is ≤ 255, for **any** float — including the infinities and NaNs a degenerate ray can produce |
| `pitch_in_range` | after any drag, any distance, either direction, the camera's pitch is still within ±89°, so it can never flip |
| `bounce_depth` | from any hit, any ray and any starting weight, the reflection recursion returns within `MAX_DEPTH` bounces — the adaptive cutoff can only end a chain sooner, never later |

All four are about structure and integer bounds, never float precision. That
is forced: Bend's `F32` operations are declared as `law F32.add` and friends,
open claims with no computational content, so no proof can see inside a float.

The design follows from that. The camera's pitch is stored in **tenths of a
degree as a `U32`** (0…1780, decoding to −89.0…+89.0) rather than as a float,
and the colour clamp is redone over `U32` after the float clamp, so both bounds
live where they can be established. Neither costs anything: `U32.cmp` compiles
to a single native comparison.

The recurring trick is that a `match` on a `Bool` or `Cmp` does not tell the
checker which way the test went, so the lemma carries the comparison's result
as an equation and case-splits on that:

```python
law cap_go_ok:
  for +n: U32
  for c: Cmp
  for h: {U32.cmp(n, R.Color.MAX()) == c : Cmp}
  {U32.is_le(R.Color.cap.go(c, n), R.Color.MAX()) == True{} : Bool}
```

`bounce_depth` is stated over `Trace.depth`, which counts the bounces `Trace`
takes on the same inputs. A function returning a colour gives a proof nothing
to measure, so the count is a separate def — but the two share their
ray-generation defs (`Trace.org`, `Trace.dir`), so they step in lockstep and
the law bounds the renderer rather than a copy of it.

Each law was checked against a deliberate break — uncapping the colour clamp,
replacing a quadrant with a constant `Pix`, uncapping the pitch, and counting
two per bounce — and each break fails the gate.

## Layout

| file | |
| --- | --- |
| `vec.bend` | 3D float vectors |
| `scene.bend` | geometry, materials, lighting, and the bounded reflection recursion |
| `render.bend` | camera, colour packing, and the parallel quadtree split |
| `main.bend` | the `App`: window, event fold, frame cache |
| `bench.bend` | headless timing harness |
| `LAWS.bend` | the four claims |
| `PROOF.bend` | their proofs, plus the arithmetic lemmas |
| `run.sh` | toolchain check, proof gate, build, bench, launch |
| `NOTES-BEND.md` | rough edges hit along the way, written up for upstream |
