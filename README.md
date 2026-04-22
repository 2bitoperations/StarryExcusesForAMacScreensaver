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
2. [x] **Planet phase calculation** — Implemented Earth-Sun-planet phase angle computation with per-planet illuminated fraction and waxing sign.
3. **Coarse geolocation** — Observer location is hardcoded to Austin, TX (30.2672°N, 97.7431°W). Detect coarse location from system timezone or CoreLocation.
4. **Visual tuning** — Confirm all planet textures look right at runtime. Tweak band colors, Great Red Spot, limb darkening, storm details, and noise as needed.

## Provenance
Fork of https://github.com/kimar/DeveloperExcuses and https://github.com/evangreen/starryn 

And feel free to fork and contribute ;-)

## Getting started
Open up *DeveloperExcuses.xcodeproj* using Xcode and hit Cmd+B to build it. That's it.

## License

See [LICENSE.md](LICENSE.md)
