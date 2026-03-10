# Future Work

Deferred optimizations and planned features.

---

## 1. Debug Overlay Recreates Objects Every Frame

**File:** `DebugLayerRenderer.swift`, `update(drawData:effectiveEnabled:)` (~line 62)

**Problem:** Every time the overlay text changes (and periodically even when it hasn't, due to the update-interval check), the method re-creates an `NSFont`, two `NSColor` instances, and an attributes dictionary from scratch. These are AppKit heap allocations on the hot path.

**Suggested fix:** Promote the `NSFont`, `NSColor`, and attributes dictionary to stored properties initialized once at `init` time (or lazily on first use). The CGContext pixel buffer (`var bytes`) could also be reused across frames if its dimensions haven't changed.

**Impact:** Low. The update-interval gate (~0.25 s) already throttles how often this runs, so the per-frame cost is minimal in practice. Worth doing for cleanliness, not urgency.

---

## 2. GPU Sync / Triple-Buffering

**File:** `StarryMetalRenderer.swift`

**Problem:** The renderer currently uses `commandBuffer.waitUntilCompleted()` in the headless path (lines ~1156, ~1573) and a synchronous `commit()` in the GPU path without any in-flight-frame management. This means the CPU blocks until the GPU finishes each frame before preparing the next one, leaving the GPU idle while the CPU builds sprite data and vice versa.

**Suggested fix:** Implement triple-buffering with a `DispatchSemaphore(value: 3)`:
1. Create three sets of sprite staging buffers.
2. Signal the semaphore in each command buffer's `addCompletedHandler`.
3. Wait on the semaphore at the start of each frame to ensure at most 3 frames are in flight.
4. Rotate through the buffer sets with a frame index modulo 3.

This decouples CPU and GPU work, allowing both to stay busy. The headless path uses `waitUntilCompleted()` intentionally (it needs the pixels back synchronously), so only the GPU-rendered path would benefit.

**Impact:** Medium-High. This is the single largest remaining optimization opportunity. On machines where the GPU is the bottleneck, it won't help much, but on CPU-bound frames (lots of sprites, debug overlay active) it could meaningfully smooth out frame pacing and reduce dropped frames.

**Tradeoffs:** Adds complexity (buffer rotation, semaphore lifecycle, careful teardown on resize). The current single-buffered approach is simple and correct — only pursue this if profiling shows CPU-GPU serialization is actually a bottleneck.

---

## 3. Coalesce Blit Command Encoders

**File:** `StarryMetalRenderer.swift`, `uploadSprites(...)` (~line 1741) and `blitCopy(...)` (~line 1990)

**Problem:** Each call to `uploadSprites` and `blitCopy` creates its own `MTLBlitCommandEncoder`, encodes one copy, and ends it. In a typical frame there are 3 sprite uploads (base, satellites, shooting stars) plus potential snapshot blits, each getting a separate encoder. Creating and finalizing a blit encoder has non-trivial Metal overhead.

**Suggested fix:** Refactor so that a single blit encoder is created per command buffer, passed through to all copy operations that need it, and ended once after all blits are queued. Something like:

```swift
guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
blit.label = "Frame \(frameIndex) uploads"
uploadSprites(into: &baseBuf, sprites: baseSprites, blit: blit, ...)
uploadSprites(into: &satBuf,  sprites: satSprites,  blit: blit, ...)
uploadSprites(into: &shootBuf, sprites: shootSprites, blit: blit, ...)
blit.endEncoding()
```

**Impact:** Low-Medium. Metal encoder creation has some overhead, but for 3-5 blits per frame it's unlikely to be measurable. Worth doing as a cleanup if the upload path is being refactored for other reasons (e.g., triple-buffering).

**Tradeoffs:** Slightly couples the upload call sites since they'd share an encoder. The current design is clean — each upload is self-contained. Only change this alongside a larger rendering pipeline refactor.

---

# Features

---

## 4. Visible Planets and Minor Planets

Render real solar system bodies in the night sky when they'd actually be visible "tonight" from the user's location.

### Scope

**Major planets** (all non-Earth): Mercury, Venus, Mars, Jupiter, Saturn, Uranus, Neptune.

**Minor planets** — dwarf planets and likely-round TNOs:
- IAU dwarf planets: Ceres, Pluto, Eris, Haumea, Makemake
- Likely spherical TNOs: Gonggong, Quaoar, Sedna, Orcus, and others with strong evidence of hydrostatic equilibrium (roughly 10–15 bodies total; the exact list can be refined at implementation time as new observations come in)

**Stretch goal — moons:** For planets that have them, render their major moons at an appropriate tiny scale if feasible without visual clutter. Jupiter's Galilean moons and Saturn's Titan are the obvious candidates; deep-sky moons of Uranus/Neptune/Pluto are probably too small to matter.

### Location

Use Core Location to get the user's coarse position (city-level accuracy is fine — we only need it for rise/set and altitude calculations). If location services are unavailable or denied, default to **Westcliffe, CO, USA** (38.1305° N, 105.4614° W) — one of the darkest sky communities in the US and a fitting fallback for a starry screensaver.

### Rendering

Bodies should be rendered as tiny sprites in the sky portion of the screen, positioned according to their computed altitude and azimuth projected onto our flat viewport. Brightness should roughly reflect apparent magnitude. The intent is subtle realism — these should look like slightly-brighter-than-average "stars" with maybe a hint of color (ruddy Mars, pale-yellow Saturn, blue-white Venus), not detailed planetary discs.

### Ephemeris

Computing planetary positions requires an ephemeris. Options to investigate:

1. **VSOP87 / simplified analytical** — Classical series expansions for major planets. Compact, no network required, accurate to arcminute-level for centuries around J2000. Public domain. Would need a Swift implementation or port.
2. **JPL Horizons API** — Extremely accurate, covers everything including minor planets and moons. Requires network access, which may be undesirable for a screensaver. Could be used to pre-generate lookup tables at build time.
3. **Hybrid** — Use analytical series for major planets (offline), fetch minor planet positions from Horizons at launch or on a slow timer (daily cadence is fine; they don't move fast).

Whichever approach we use, the computation should happen off the render loop — positions update at most once per minute.

### Configuration

- Toggle: "Show planets" (default on)
- Toggle: "Show minor planets" (default on)
- Location override field or "use current location" checkbox

### Implementation Notes

This is a significant feature. Suggested breakdown:
1. Location manager (Core Location wrapper with Westcliffe fallback)
2. Major planet ephemeris (VSOP87 or similar)
3. Altitude/azimuth projection for the viewport
4. Planet sprites in `SkylineCoreRenderer` or a new `PlanetsLayerRenderer`
5. Minor planet positions (likely Horizons-based)
6. Configuration panel additions
7. Stretch: planetary moon positions and rendering
