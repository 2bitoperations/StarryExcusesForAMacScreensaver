# StarryExcusesForAMacScreensaver

[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat)](LICENSE.md)
[![Build & Test](https://github.com/2bitoperations/StarryExcusesForAMacScreensaver/actions/workflows/build.yml/badge.svg)](https://github.com/2bitoperations/StarryExcusesForAMacScreensaver/actions)

A macOS screensaver inspired by the AfterDark *Starry Night* screensaver from the late 90s.

## What's here

The entire simulation and rendering engine is written in **Rust + wgpu** (`starry-rs/`).
On macOS it ships as a `.saver` bundle: a thin Swift wrapper (`starry-saver-osx/`) loads
the Rust dylib and hands it a `CAMetalLayer` to draw into.

The original Swift/Metal implementation that predates the Rust port has been removed.
It served as the visual ground-truth during the port; with the Rust side at full feature
parity there was no reason to keep two codebases.

## Features

- Procedural city skyline with randomised buildings and window lights
- Stars, shooting stars, satellites, a flashing rooftop beacon
- Moon with real-world phase (Julian-day math), traversal arc, three terminator modes
- All 8 planets with Keplerian J2000 ephemeris, procedural textures, phase shading,
  and Saturn's rings (three ring styles)
- Galilean moons (Io, Europa, Ganymede, Callisto) and Titan as orbital dot sprites
- Live options panel with editable value fields, per-tab restore-defaults, and a
  "locked to Jupiter scale" planet-sizing mode
- FPS / CPU debug overlay
- Headless `--dump-png` mode; deterministic seed mode for regression testing

## Building (macOS)

```bash
cd starry-rs/starry-saver-osx
bash build-saver.sh        # builds Rust + Swift, installs to ~/Library/Screen Savers/
killall legacyScreenSaver  # force-reload the screensaver host before testing
```

See [`starry-rs/README.md`](starry-rs/README.md) for the full build guide, CLI flags,
and cross-platform (Linux / Windows) instructions.

## Provenance

Originally forked from https://github.com/kimar/DeveloperExcuses and
https://github.com/evangreen/starryn.

## License

See [LICENSE.md](LICENSE.md)
