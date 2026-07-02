---
name: hoosiertrail-render-pipeline
description: Use when working on the hoosierTrail (Oregon Trail Revisited) game's visual asset pipeline — Blender rendering of wagons/oxen/drivers/wheels, SDXL + LoRA backdrop generation, SVG composition of raster + vector layers, mesh manipulation (posing, gun-removal, yoke surgery, wheel labeling), or any related artifact. Captures patterns and gotchas accumulated across many sessions so they aren't re-derived.
---

# hoosierTrail Render Pipeline

The game uses a hybrid SVG-plus-raster art pipeline. SVG handles the layout, color tinting, and per-instance variants; rasters come from Blender (3D models → animated sprite cycles) and SDXL+LoRA (painted landscape backdrops). The SVG composes them at fixed pixel coordinates.

This skill is the index to "how we make a frame." Specific working scripts live in the repo at `/home/eric/projects/hoosierTrail/tools/`; the dialed-in flags live in `tools/blender/render-yoke-set.sh`.

## Project layout

```
/home/eric/projects/hoosierTrail/              ← the repo (jj-colocated)
~/datasets/ot-revisited/lora-train/            ← LoRA training data (~2.5GB), kept outside the repo
```

The `hoosierTrail-wagon-bg/` sibling worktree was retired 2026-05-23 (it had been a pre-jj-adoption convenience; consolidation surfaced fewer stale-fork-point merge surprises). Don't `git push` directly — use `jj git push --bookmark <name>` (see in-repo `CLAUDE.md`).

| Path | Role |
|---|---|
| `tools/blender/models/*.glb` | Source 3D models (Mixamo cowboy, ox-walk, covered-wagon, prairie-schooner chassis, conestoga) |
| `tools/blender/render_wagon.py` | Single-frame wagon body render (no wheels) |
| `tools/blender/render_wheels.py` | N-frame rotating wheel cycle |
| `tools/blender/render_animation.py` | N-frame walk cycle (ox, yoke, etc.) |
| `tools/blender/pose_cowboy_seated.py` | Mixamo rig → seated pose + gun removal |
| `tools/blender/label_wagon_parts.py` | One-shot manifest generator (see Manifest pattern below) |
| `tools/blender/render-yoke-set.sh` | **CANONICAL RECIPE** — re-generates every sprite set with the dialed-in flags |
| `tools/blender/models/covered-wagon-labels.json` | Per-part labels (rotating vs stationary vs hidden) |
| `static/wagon-bg/wagon-blender/` | Rendered PNG outputs |
| `static/wagon-bg/index.html` | Browser gallery served by a `nocache_server.py` |
| `src/lib/ui/wagon/wagon-svg/PrairieSchooner.svelte` | SVG that composites body + wheel-cycle + driver + ox-team |

**`render-yoke-set.sh` is the source of truth for production flags.** Don't tweak env vars ad hoc — edit that script and re-run.

## Component → PNG mapping

| Output PNG | Source GLB | Key flags |
|---|---|---|
| `prairie-schooner-body--nowheels.png` | `covered-wagon.glb` (NOT prairie-schooner.glb — that's chassis-only and misnamed) | `HIDE_MATERIAL=1011 FLIP_VIEW=1 TONGUE_LIFT_DEG=20 TONGUE_PIVOT_X=-1.7 TONGUE_PIVOT_Z=1.0 TONGUE_PIVOT_SIGN=-1` |
| `prairie-schooner-wheels-frames/wheel--00..23.png` | `covered-wagon.glb` | `FLIP_VIEW=1 DIRECT_VERT_ROT=1 LABEL_MANIFEST=...labels.json WHEEL_CYCLE_FRACTION=-1.0` (24 frames at 15°) |
| `ox-yoke-wide-frames/yoke-wide--00..11.png` | `ox-walk.glb` | `YOKE_Y_SCALE=1.25 UV_COMP_BOOST=2.0 YOKE_BOW_STRETCH=1.2 YOKE_PEG_SCALE=2.0 FAKERET_KILL_RINGS=1.5 HIDE_NAMES=csati_bor,...` |
| `cowboy-driver-side.png` | `cowboy-driver.glb` | hand-cropped from `cowboy-side-rein2--seated.png` produced by `pose_cowboy_seated.py` |

After every render, all 12-or-N wheel frames + the body PNG get cropped to their **shared union bbox** so the SVG composes them at identical pixel coordinates (see Union-bbox crop below).

## Manifest-driven part labeling

The fundamental problem: covered-wagon.glb's "wheels" material `1011` also contains the brake hardware, axle bars, brake brackets, and other chassis bits — **no heuristic filter (radius / axial-tolerance / Z-extent / brake-hide zone) cleanly separates wheels from non-wheels**. After a long fight with heuristics, the solution was to label each mesh part once and let `render_wheels.py` trust the labels.

The flow:

1. **Generate labels:**
   ```
   AXIAL_THIN_MAX=0.30 blender -b -P tools/blender/label_wagon_parts.py -- \
     tools/blender/models/covered-wagon.glb 1011 \
     tools/blender/models/covered-wagon-labels.json
   ```
   Loose-separates the wheel-material mesh into 643 parts, classifies each by geometry, writes a JSON manifest mapping each part centroid → label (`wheel_FL`, `wheel_FR`, `wheel_RL`, `wheel_RR`, `chassis`, `brake`, `hub_attachment`).

2. **Render with manifest:**
   ```
   LABEL_MANIFEST=tools/blender/models/covered-wagon-labels.json \
   blender -b -P tools/blender/render_wheels.py -- ...
   ```
   `render_wheels.py` loose-separates the same mesh on import, matches each fresh part to its manifest entry by **nearest centroid** (because object names change across imports, but geometry is deterministic), then routes parts into `wheel_groups[hub_idx]` (rotating), `stationary` (visible, fixed), or hidden (`hide_render = True`).

**Critical classification rules in `label_wagon_parts.py`:**

| Test | Label |
|---|---|
| `y_ext > 0.5` | `chassis` (long axially → axle bar between wheels) |
| `z_ext > 0.7 AND x_ext > 0.7 AND axial_offset < 0.30 AND in_plane_d < 0.2` | `wheel_<nearest>` (full rim — rotationally-symmetric circle, both X and Z spans = wheel diameter, centroid at hub) |
| `z_ext > 0.7` (alone) | `brake` (tall + narrow Z = brake post) |
| Within in-plane radius `0.65` and axial offset `< 0.30` of nearest hub | `wheel_<nearest>` |
| Axially offset `> 0.30` but near hub | `hub_attachment` (axle stub, etc.) |
| Else | `chassis` |

**Gotcha that ate hours:** without the X-extent check on the rim rule, the rim (one connected rotationally-symmetric mesh whose Z-extent = wheel diameter ≈ 1m) was misclassified as `brake` (z-tall). The wheels rendered with spokes but no outer rim. Brake POSTS have tall Z but narrow X; rims have both tall.

**`AXIAL_THIN_MAX=0.30`** is required for covered-wagon — the wheel mesh is unusually thick (33cm axial extent including the hub assembly). The default `0.20` clips off half the wheel parts.

**True wheel hub coordinates** (from ground-contact analysis, not bbox centers which are biased by chassis hardware):
- Front-left: `(-1.121, -0.774, 0.49)`
- Front-right: `(-1.123, +0.774, 0.49)`
- Rear-left:  `(+1.009, -0.779, 0.573)`
- Rear-right: `(+1.010, +0.779, 0.573)`

Edit the JSON manifest directly if any part is mislabeled — it's plain text, the changes survive re-renders.

## Wheel rotation cycle math

**Use 24 frames covering a full 360° rotation** (`WHEEL_CYCLE_FRACTION=-1.0`, 24 frames at 15°/frame). The wheel returns to its EXACT starting orientation at the loop — no reliance on rotational symmetry.

Why partial cycles fail: the covered-wagon hub has bolt patterns with lower-fold symmetry than the spokes (12-fold). 60° and 30° partial cycles assume 6-fold or 12-fold symmetry, but the hub bolts visibly snap at the loop. Measured wraparound deltas:

| Cycle | Wraparound delta | Typical step | Result |
|---|---|---|---|
| 60° (12 frames, 5°/frame) | 5.75 | ~6.0 | mathematically close but visibly snaps |
| 30° (12 frames, 2.5°/frame) | 3.10 | ~3.36 | still visibly snaps (hub features) |
| **360° (24 frames, 15°/frame)** | **8.06** | **8.02-8.27** | **perfectly seamless** |

Asset cost: 24 PNGs × ~260KB ≈ 6.3 MB. Acceptable.

`render_wheels.py` step math: `step = cycle / N_frames`, frame i rotation = `i × step`. So 24 frames at cycle `-1.0` (=-360°) gives -15°/frame. Frame 0 at 0°, frame 23 at -345°; the implicit "frame 24" is -360° = exactly frame 0 again.

## Direct vertex rotation

`render_wheels.py` uses `DIRECT_VERT_ROT=1` to rotate wheel parts. The Blender "create empty at hub, parent parts to it, keyframe empty rotation" approach has a `keep_transform` interaction that orbits parts around the SCENE origin instead of spinning them in place when the glTF importer's Y-up→Z-up conversion has baked a non-identity parent rotation. Direct vertex math bypasses the whole parenting machinery:

```python
# Rotate vertex v around axis axle_idx (Y for X-length wagons) through hub:
oa, ob = (other two axes)
da = v[oa] - hub[oa]
db = v[ob] - hub[ob]
v[oa] = hub[oa] + da*cos(θ) + db*sin(θ)
v[ob] = hub[ob] - da*sin(θ) + db*cos(θ)
```

Apply `bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)` to parts BEFORE rotating verts so `matrix_world` is identity.

## SVG composition

The SVG (e.g., `PrairieSchooner.svelte`) overlays the body and wheel-cycle PNGs at identical pixel coordinates. Three rules:

**1. Shared union bbox.** After every Blender re-render, run the post-process Python in `render-yoke-set.sh` that crops body + all wheel frames to their **union bbox**. Each PNG ends up with content at the same pixel offsets so SVG composition aligns automatically.

```python
from PIL import Image
import glob
paths = ['.../body.png'] + sorted(glob.glob('.../wheel--*.png'))
bb = None
for p in paths:
    b = Image.open(p).getbbox()
    if b: bb = b if bb is None else (min(bb[0],b[0]), min(bb[1],b[1]), max(bb[2],b[2]), max(bb[3],b[3]))
for p in paths: Image.open(p).crop(bb).save(p)
```

**Always re-crop both body and wheels together**, never just one. Cropping an already-cropped image to a different bbox shifts content.

**2. Width × height matches union aspect.** `PrairieSchooner.svelte` uses `width=65 height=H` where `H = 65 / aspect` of the union bbox. Current production with 24-frame full rotation gives union `1430×571` (aspect 2.50) → `height=26.0`. Use `preserveAspectRatio="xMidYMid meet"` so the image fits the box without distortion.

**3. Cache-bust on re-renders.** SvelteKit / Vite happily serve old cached PNGs. Append `?v=N` to the image hrefs in the SVG and bump `N` whenever you re-render. Saves the "Dave's seeing janky frames" debugging round-trip.

## Cowboy posing (Mixamo rig)

`cowboy-driver.glb` is a Mixamo-rigged emigrant. Imports at scale 1.0 ≈ 7m tall — scale to 0.25 for ~1.75m human.

`pose_cowboy_seated.py` applies seated-on-bench pose by setting **world-axis quaternions per bone** then converting to bone-local rotation via the rest-pose inverse:

```python
local_q = rest_world_3x3.inverted() @ world_q.to_matrix() @ rest_world_3x3
```

Without this conversion the rotations apply in bone-local space (twisted, wrong axes). The dialed-in `SEATED_POSE` dict has wrist rotation `±50°` around Y (palms-down, thumbs-inside), finger curl, hip flex, knee bend, feet **flat** (rotation 0 — not pointed down).

**Gun removal:** the cowboy has an embedded pistol mesh. Loose-separation gives a forest of islands; the gun's are at bbox `0.55 < |cx| < 0.95, -0.30 < cy < 0.40, -0.10 < cz < 1.30` (relative to character origin). The `pose_cowboy_seated.py` script deletes islands 471-614 inside that volume. Verify visually after — there's no clean material/group separation.

## Yoke shape adjustments (ox + yoke)

`ox-walk.glb` ships with an attached harness mesh (yoke, ropes, chains). Production controls (in `render-yoke-set.sh`):

| Env var | Effect |
|---|---|
| `HIDE_HARNESS=1` | Strip the entire harness — for tile-able multi-ox teams |
| `KEEP_ONLY="fakeret,torus"` | Render JUST the yoke (no ox, no straps) |
| `HIDE_NAMES="csati_bor,csati_huzo,csti_krom_krom,csti_krom.001,krom_krom_0"` | Selectively hide rope/chain/ring meshes |
| `YOKE_Y_SCALE=1.25` | Widen yoke along body axis to fit 10° turning |
| `UV_COMP_BOOST=2.0` | Compensate UVs `2×` the geom scale to keep wood-grain proportional |
| `YOKE_BOW_STRETCH=1.2` | Stretch bow wood downward (z<1.7) so bows wrap UNDER neck |
| `YOKE_PEG_SCALE=2.0` + `YOKE_PEG_OUTER_X=0.7` | Enlarge outer pegs at the arch ends only |
| `FAKERET_KILL_RINGS=1.5` | Delete small fakeret ring-islands at z<1.5 (decorative metal rings that clipped through ox necks) |
| `OX_PAIR=1 OX_PAIR_OFFSET=1.6 CAMERA_3Q_DEG=-30` | Yoked pair at 3/4 view (showcase) |

When scaling geometry along an axis, ALWAYS compensate the UVs along the SAME world-axis (whichever has the higher correlation with the scaling direction) to prevent texture stretch. `UV_COMP_BOOST` is the multiplier — empirically `2.0` works for `Y_SCALE=1.25`.

## SDXL + LoRA backdrop generation

The painted-style landscape backdrops come from SDXL + a custom LoRA `ht_landscape` trained on hand-curated landscape stills.

- **LoRA versions:**
  - `v1` (initial) — generic landscapes
  - `v2_2000` (current production) — current preferred; `generate.py` auto-loads this
  - **`storm-mood` retrain — DEFERRED.** Forces storms to ~95% sky which dominates the composition; the natural-looking storm look was lost. Curated retrain needed.

- **Training data:** `~/datasets/ot-revisited/lora-train/` (~2.5 GB). Kept outside the repo (curated data, not source — moved out 2026-05-23 when the wagon-bg sibling worktree was retired).

- **Prompt convention:** use "horizon-vista" phrasing for the single-backdrop variants per biome (no time-of-day mixed in — weather drives variant selection, time-of-day comes from a separate scene tint layer).

- **Output usage:** rendered tiles go to `static/wagon-bg/backdrops/*`. `BackdropPainting.svelte` is the default backdrop renderer in `WagonScene.svelte`.

### What the pipeline can and CANNOT render (category rule, proven 2026-05-27)

`ht_landscape` + SDXL only works for **natural-landscape landmarks** (rock formations, rivers, plains, springs — chimney_rock and scotts_bluff validated). **Architecture is broken with this pipeline**: 29 iterations on Fort Laramie proved the LoRA pulls buildings into far-horizon landscape compositions, SDXL tiles/duplicates content at 3:1 aspect (rows of identical buildings), and multi-building prompts collapse to one cartoonish building even at 3:2. Best fort result ever achieved = a single Old-Bedlam-style building (v23/seed 830020), shipped as a stopgap.

- Check natural vs man-made BEFORE spending iteration budget. Man-made (forts, missions, ranches, trading posts) → **wait for #1187** (architectural pipeline: RealVisXL/DreamShaper + 3:2 + outpainting) or accept a single-building stopgap. Hybrid/unsure → ask Dave.

### Fort composition rule (applies to any architecture pipeline, Dave 2026-05-27)

When a backdrop depicts a fort/man-made landmark: **1–3 prominent buildings** (never a sprawl/town); **exactly one flagpole + one American flag** (stack anti-multi-flag negatives: `multiple flagpoles, multiple flags, two flags, many flagpoles, flag cluster, row of flags`); **teepees in the far foreground separated from the fort by ≥100 yards of explicit open prairie** (else the model amalgamates them into one cluster — use spatial language verbatim); **minimal horses/wagons/people** (`a single small covered wagon with one ox team`, anti-crowd negatives: `many horses, herd of horses, cavalry, mounted soldiers, dozens of people, crowd, busy scene, large wagon train, dozens of wagons`). The dialed-in v8 Fort Laramie prompt in the archive (`~/projects/aiImprove/memory-archive-2026-07-02/`, feedback_fort_composition_rule) is the template to mirror for the next fort.

### Retraining the ht_landscape LoRA (kohya-sd-scripts)

The LoRA was trained with **`~/projects/kohya-sd-scripts/`** (clone of github.com/kohya-ss/sd-scripts, `.venv` inside, ~5 GB; dormant since 2026-05-01) on the data at `~/datasets/ot-revisited/lora-train/`.

**⚠️ Load-bearing local patch (committed locally 2026-07-02, NOT upstream):** `library/sdxl_model_util.py` loads both text encoders in **fp16 instead of fp32** — without it, TE loading OOMs during init on flattop's 8 GB RTX 3070 (the TE2 step). Quality loss is negligible because `cache_text_encoder_outputs` uses the TEs once to pre-compute embeddings, then unloads. If the clone is ever updated/re-cloned, **re-apply this patch before training** (it's a local commit on the clone's main; `git log --oneline -1` there shows it).

## Draft-animal models: sourcing, provenance, rigging

- **`ox-walk.glb` provenance** (recorded nowhere else): Sketchfab **"Double Ox walk" by honved444, CC-BY-4.0**, pre-rigged + walk-animated (action `Ox_ walk_draft`); attribution metadata lives only in the GLB's `asset.extras`. The donkey (soniarocha, 12 actions incl. walk) is likewise pre-rigged+animated.
- **The sourcing path for any new draft animal:** free, CC-licensed, **pre-rigged AND pre-animated** quadruped GLB on Sketchfab → render its built-in action via `tools/blender/render_animation.py` → union-bbox crop. Dave's rules: never pay, CC-BY fine (attribution only), reject copyrighted characters. Sketchfab downloads need a logged-in browser (Dave does that step).
- **⚠️ Headless auto-rigging a STATIC mesh does not work** (proven on #216, 2026-05-28): a mesh sculpted mid-gallop can't be reposed headless (it "leaps in place"); non-watertight meshes fail heat/auto-weights and envelope weights only flail loose parts. Pre-rigged+animated or nothing — a human authored the walk in a viewport, and that can't be reproduced with `blender -b`. Corollary: **verify motion by viewing the render, never by pixel-diff numbers** (the "walking" pixels were flailing bridle reins).
- **Mule status:** no mule GLB — mule teams currently render AS OXEN because `OxTeam.svelte`'s Blender branch (`useBlenderTeam:true`) ignores `isMule` (the flag only steered the dormant SVG fallback). Working path: mule-ify the walking donkey (longer ears, roached mane, reskin via `stylize.py`, scale up) or base on "Low Poly Horse (Rigged)" by Yanez Designs (CC-BY-4.0); harness as SVG overlay, no yoke.

## SVG generation paths (beyond hand-authored)

When hand-authored SVG hits its ceiling (complex landmarks, signage, etc.):

| Tool | Strength |
|---|---|
| **StarVector** (HuggingFace) | Vision→SVG model. Good for converting raster mockups to SVG paths. |
| **OmniSVG** | Specialized SVG generation model |
| **Inkscape CLI** (via the `claude-skills` bundle) | Vector-true import/manipulation of existing SVGs. Used for trace-bitmap pipelines. |

For repeating SVG patterns (rust, weathered wood), generate via FLUX (see `static/wagon-bg/wagon-tex-flux/`) and use as raster pattern fills inside SVG `<pattern>` elements.

## Asset gallery for inspecting renders

Dave's rule: **show generated images in a running dev server, not via inline reads.** Every render/debug image goes into the running `nocache_server.py` directory + an `index.html` showing it. Pattern:

1. The wagon-bg gallery lives at `static/wagon-bg/index.html` (project-static, served at `/wagon-bg/index.html` by Vite).
2. **Vite doesn't auto-index directories** — `/wagon-bg/` returns 404. Spin up an additional `nocache_server.py` rooted at `static/wagon-bg/` on a free port (8768+) so the gallery is reachable at `/` and relative image paths resolve.
3. Add a `<details>`-collapsed strip section per new variant. Cycling animation via `class="cycle" data-base="..."` (the gallery has a `setInterval(167)` driver for 6 fps).

```bash
python3 /tmp/nocache_server.py /home/eric/projects/hoosierTrail/static/wagon-bg/ 8768
```

For non-gallery one-offs (cowboy-views, oxteam-view, wagon-train-views) the convention is `/tmp/<view-name>/` with its own `index.html` + nocache_server on a sequential port.

## Common pitfalls

| Pitfall | Counter |
|---|---|
| **Commit PNGs before re-rendering.** Lossy/destructive Blender re-renders have overwritten irreplaceable cropped outputs (`prairie-schooner-body--nowheels.png` lost once). | Stage any high-value PNG in jj before a re-render that might fail. |
| **Material 1011 in covered-wagon.glb contains MORE than wheels.** Brake hardware, axle bars, hub assemblies share the material. | Use the manifest pattern; heuristics will fail. |
| **`prairie-schooner.glb` is misnamed.** It's chassis-only (no body, no canvas) with a single shared `material_0`. The actual "prairie schooner" body lives in `covered-wagon.glb`. | Use `covered-wagon.glb` for any body + wheels output. |
| **bbox-center hubs are biased toward chassis hardware.** | Use ground-contact analysis: find verts at min-Z within each wheel quadrant. Those rim-bottom contact points give clean (X, Y) hub centers. |
| **K-means nearest-hub assignment with in-plane distance** can't distinguish front-left from front-right (same X, only Y differs). | Use **full 3D distance** for nearest-hub. |
| **Browser cache holds stale PNGs after re-render.** | `?v=N` cache-bust suffix on every image href in the SVG; bump on each re-render. |
| **Vite dev server doesn't serve directory indexes.** | Spin a `nocache_server.py` for the gallery; don't rely on `/wagon-bg/`. |
| **`AXIAL_THIN_MAX=0.20` (default) clips half the wheel** on covered-wagon. | Use `0.30` — covered-wagon wheels are 33cm thick. |
| **12-frame partial-rotation cycles snap at the loop** because the hub's bolt pattern has lower-than-12-fold symmetry. | Render a full 360° in 24 frames (15°/frame). Wraparound delta becomes indistinguishable from any normal step. |
| **Scaling geometry without UV compensation stretches the texture.** | Apply `UV_COMP_BOOST` along the same world-axis correlated with the scaling direction. |
| **Mixamo rig rotations applied bone-local look wrong.** | Convert world-axis quaternions to bone-local via `rest_world_3x3.inverted() @ world_q.to_matrix() @ rest_world_3x3`. |

## Workflow when adding/changing a sprite set

1. Edit the relevant Python (`render_wheels.py`, `render_animation.py`, `pose_cowboy_seated.py`) or env-var override.
2. **Update `tools/blender/render-yoke-set.sh`** to record the new flag. Don't pass env vars ad hoc from the shell — the script is the source of truth.
3. Run the script (or the specific section). Renders into `static/wagon-bg/wagon-blender/<set>/`.
4. The post-script Python crops body + wheels to union bbox.
5. Bump `?v=N` in `PrairieSchooner.svelte` (or the relevant Svelte component) so browser caches refresh.
6. Open `/dev/wagon-detail` (Vite at 5174) and the wagon-bg gallery (`nocache_server` at 8768) to visually verify.
7. Run `npm run check` — typecheck must pass before committing.

## Related memory entries

These per-host memory files complement this skill (read them if relevant):

- `reference_hoosiertrail_wagon_models.md` — GLB → PNG mapping, wheel-rotation history, lessons learned
- `reference_hoosiertrail_jj.md` — jj workflow specific to this repo
- `project_hoosiertrail_phase_2_lora.md` — storm-mood LoRA retrain status
- `project_hoosiertrail_svg_generation.md` — StarVector / OmniSVG / Inkscape paths
- `feedback_show_generated_images_in_dev_server.md` — the "no inline reads" rule
