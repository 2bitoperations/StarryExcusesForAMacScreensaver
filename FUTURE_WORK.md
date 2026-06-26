# Future Work

---

## 1. Dynamic Observer Location

The planetary ephemeris (`planet.rs`) uses a hardcoded Austin TX observer (30.27°N, 97.74°W).
On macOS, Core Location could supply a coarse city-level fix; fall back to a config knob
(or a dark-sky default like Westcliffe, CO) when unavailable or on non-macOS platforms.

---

## 2. Minor Planets

The 8 major planets are rendered with full Keplerian ephemeris. Extend to IAU dwarf planets
(Ceres, Eris, Haumea, Makemake) and likely-round TNOs (Gonggong, Quaoar, Sedna, Orcus, …).
Simplified circular-orbit elements are sufficient for the visual; positional accuracy to
within a few arcminutes is fine. JPL Horizons can provide elements at build time if needed.
