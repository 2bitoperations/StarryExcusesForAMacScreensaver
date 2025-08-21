#  Aider-Prompts

this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. change the preview image of the screensaver that shows in the list of available screensavers to look like what the screen saver actually renders. the preview when the screensaver is selected is fine, we don't need to change that.

this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. analyze the code in StarryEngine.swift in particular. we want to add a new layer that renders "satellites" in the same style as the original screensaver. for this first pass, add the layer and choose sensible defaults for any potential configuration options. the satellite layer should be in front of the building/stars layer, and behind the moon layer. to aid initial testing, satellites should spawn frequently - at least once per second.

this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. add configuration options in StarryConfigSheetController and StarryDefaultsManager to enable or disable the layer, a slider to control the number of satellites, and any other reasonable options. Pass these new options through from StarryExcuseForAView  to the constructor of the satellite layer renderer. do not edit the xib file yet for these configuration options - we'll do this in another pass.


this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's.  we have recently added options to StarryConfigSheetController relevant to the satellite layer in StarryEngine.swift. edit the StarryExcusesConfigSheet.xib file to provide widgets for these new options. resize the options panel as appropriate. do not remove any other options from the xib file.

(the initial implementation of this basically just made the satellites lines rather than dots. to iterate later...)
this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. analyze the code in StarryEngine.swift and SatellitesLayerRenderer.swift and see if there is a way we can make the motion of the satellites smoother (right now we change each satellite position by many pixels with each update, leading to jerky motion).

this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. analyze the code in StarryEngine.swift. add a new layer that, if enabled, will draw some debug text to the top-right of the screen. the debug information should include the current frames per second of rendering, the cpu used by this process, and the local date and time in ISO 24-hour format.

this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. analyze the code in StarryEngine.swift. add a toggle to StarryConfigSheetController.swift StarryDefaultsManager.swift to control the debug layer. pipe the enabled/disabled state to `StarryEngine` as appropriate. do not change StarryExcusesConfigSheet.xib at this time.


this repository contains swift code for a macos screensaver that is meant to look like the starry night screensaver from the afterdark package from the late 1980's. analyze the code in StarryExcusesConfigSheet.xib, and add a widget for the toggle to the debug layer in StarryConfigSheetController.swift.
