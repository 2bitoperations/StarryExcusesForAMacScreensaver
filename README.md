# StarryExcusesForAMacScreensaver.saver

[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat)](https://github.com/kimar/DeveloperExcuses/blob/master/LICENSE.md)

## What is this?
This is a screensaver for MacOS that tries to be an homage to the old AfterDark Starry Night screensaver from the late 90s. Largely implemented in Swift with a Metal renderer. 

## Status
Very basic implementation.
- [x] buildings
- [x] stars
- [x] flasher
- [x] configuration panel
- [ ] rain
- [x] shooting stars
- [x] satellites
- [x] moon
- [x] planets (Mercury, Venus, Mars, Jupiter, Saturn, Uranus, Neptune, Pluto — individually toggleable)

### Planets TODO
1. **Verify render order** — Planets draw after the building layer and before the moon in `encodeCompositeAndMoon()`. This *should* place them above all buildings and behind the moon. Visually confirm this is working correctly and adjust if needed.
2. **Planet phase calculation** — Phase is hardcoded to 1.0 (fully lit) for all planets. Implement a plausible Earth-Sun-planet phase angle calculation.
3. **Coarse geolocation** — Observer location is hardcoded to Austin, TX (30.2672°N, 97.7431°W). Detect coarse location from system timezone or CoreLocation.
4. **Saturn ring tilt visual** — Ring tilt angle is computed (Schlyter formula) and piped to the shader, but the shader does not yet dynamically adjust the ring texture orientation — it still uses the baked 22° texture. Wire the tilt into actual ring rendering.
5. **Visual tuning** — Confirm all planet textures look right at runtime. Tweak band colors, Great Red Spot, limb darkening, storm details, and noise as needed.

## Provenance
Fork of https://github.com/kimar/DeveloperExcuses and https://github.com/evangreen/starryn 

And feel free to fork and contribute ;-)

## Getting started
Open up *DeveloperExcuses.xcodeproj* using Xcode and hit Cmd+B to build it. That's it.

## License

See [LICENSE.md](LICENSE.md)
