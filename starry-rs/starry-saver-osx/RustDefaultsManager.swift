import Foundation
import ScreenSaver

// ---------------------------------------------------------------------------
// RustDefaultsManager
//
// Reads and writes screensaver preferences for the Rust/wgpu build
// (com.2bitoperations.screensaver.StarryNightRust).  Completely disjoint
// from the legacy Swift implementation — no shared types, no shared plist.
//
// Key names are the snake_case field names from starry-core/src/config.rs
// so the tomlString() output is accepted verbatim by load_config_from_toml_str.
// ---------------------------------------------------------------------------

final class RustDefaultsManager {

    static let moduleIdentifier = "com.2bitoperations.screensaver.StarryNightRust"

    private let ud: UserDefaults

    init() {
        ud = ScreenSaverDefaults(forModuleWithName: Self.moduleIdentifier)!
    }

    // MARK: - Defensive helpers

    private func d(_ key: String, default def: Double, lo: Double, hi: Double) -> Double {
        guard let n = ud.object(forKey: key) as? NSNumber else { return def }
        let v = n.doubleValue
        guard v.isFinite, v >= lo, v <= hi else { return def }
        return v
    }

    private func b(_ key: String, default def: Bool) -> Bool {
        guard ud.object(forKey: key) != nil else { return def }
        return ud.bool(forKey: key)
    }

    private func i(_ key: String, default def: Int, lo: Int, hi: Int) -> Int {
        guard let n = ud.object(forKey: key) as? NSNumber else { return def }
        let v = n.intValue
        guard v >= lo, v <= hi else { return def }
        return v
    }

    private func s(_ key: String, default def: String, valid: Set<String>) -> String {
        guard let v = ud.string(forKey: key), valid.contains(v) else { return def }
        return v
    }

    private func set(_ key: String, _ value: Any) {
        ud.set(value, forKey: key)
        ud.synchronize()
    }

    // MARK: - Sky

    var starsFraction: Double {
        get { d("stars_fraction", default: 0.5, lo: 0, hi: 1) }
        set { set("stars_fraction", max(0, min(1, newValue))) }
    }

    var lightsFraction: Double {
        get { d("lights_fraction", default: 0.25, lo: 0, hi: 1) }
        set { set("lights_fraction", max(0, min(1, newValue))) }
    }

    var clearIntervalS: Double {
        get { d("clear_interval_s", default: 120.0, lo: 1, hi: 3600) }
        set { set("clear_interval_s", max(1, min(3600, newValue))) }
    }

    var buildingHeightPctMax: Double {
        get { d("building_height_pct_max", default: 0.35, lo: 0, hi: 1) }
        set { set("building_height_pct_max", max(0, min(1, newValue))) }
    }

    // MARK: - Shooting Stars

    var shootingStarsEnabled: Bool {
        get { b("shooting_stars_enabled", default: true) }
        set { set("shooting_stars_enabled", newValue) }
    }

    var shootingStarsAvgSeconds: Double {
        get { d("shooting_stars_avg_seconds", default: 7.0, lo: 0.5, hi: 600) }
        set { set("shooting_stars_avg_seconds", max(0.5, min(600, newValue))) }
    }

    // MARK: - Satellites

    var satellitesEnabled: Bool {
        get { b("satellites_enabled", default: true) }
        set { set("satellites_enabled", newValue) }
    }

    // MARK: - Moon

    var moonEnabled: Bool {
        get { b("moon_enabled", default: true) }
        set { set("moon_enabled", newValue) }
    }

    var moonDiameterPercent: Double {
        get { d("moon_diameter_percent", default: 80.0 / 3000.0, lo: 0.001, hi: 0.25) }
        set { set("moon_diameter_percent", max(0.001, min(0.25, newValue))) }
    }

    var moonTraversalSeconds: Double {
        get { d("moon_traversal_seconds", default: 3600.0, lo: 60, hi: 43200) }
        set { set("moon_traversal_seconds", max(60, min(43200, newValue))) }
    }

    // 0 = hard, 1 = smooth, 2 = banded
    var moonTerminatorMode: Int {
        get { i("moon_terminator_mode", default: 2, lo: 0, hi: 2) }
        set { set("moon_terminator_mode", max(0, min(2, newValue))) }
    }

    var moonBrightBrightness: Double {
        get { d("moon_bright_brightness", default: 1.0, lo: 0.2, hi: 1.2) }
        set { set("moon_bright_brightness", max(0.2, min(1.2, newValue))) }
    }

    var moonDarkBrightness: Double {
        get { d("moon_dark_brightness", default: 0.15, lo: 0, hi: 0.9) }
        set { set("moon_dark_brightness", max(0, min(0.9, newValue))) }
    }

    var moonPhaseOverrideEnabled: Bool {
        get { b("moon_phase_override_enabled", default: false) }
        set { set("moon_phase_override_enabled", newValue) }
    }

    // 0.0 = new moon → 0.5 = full → 1.0 = new moon again
    var moonPhaseOverrideValue: Double {
        get { d("moon_phase_override_value", default: 0.5, lo: 0, hi: 1) }
        set { set("moon_phase_override_value", max(0, min(1, newValue))) }
    }

    // MARK: - Planets

    var planetsEnabled: Bool {
        get { b("planets_enabled", default: true) }
        set { set("planets_enabled", newValue) }
    }

    var planetMoonsEnabled: Bool {
        get { b("planet_moons_enabled", default: true) }
        set { set("planet_moons_enabled", newValue) }
    }

    // "hide" | "random" | "random-when-below"
    var planetBelowHorizonBehavior: String {
        get { s("planet_below_horizon_behavior", default: "hide",
                 valid: ["hide", "random", "random-when-below"]) }
        set { set("planet_below_horizon_behavior", newValue) }
    }

    // "forced-full" | "forced-half" | "computed"
    var planetPhaseMode: String {
        get { s("planet_phase_mode", default: "computed",
                 valid: ["forced-full", "forced-half", "computed"]) }
        set { set("planet_phase_mode", newValue) }
    }

    // "smooth" | "flat-retro" | "chunky-pixel"
    var saturnRingStyle: String {
        get { s("saturn_ring_style", default: "flat-retro",
                 valid: ["smooth", "flat-retro", "chunky-pixel"]) }
        set { set("saturn_ring_style", newValue) }
    }

    var mercurySize: Double {
        get { d("mercury_size", default: 0.00056, lo: 0, hi: 0.2) }
        set { set("mercury_size", max(0, min(0.2, newValue))) }
    }
    var venusSize: Double {
        get { d("venus_size", default: 0.00139, lo: 0, hi: 0.2) }
        set { set("venus_size", max(0, min(0.2, newValue))) }
    }
    var marsSize: Double {
        get { d("mars_size", default: 0.000784, lo: 0, hi: 0.2) }
        set { set("mars_size", max(0, min(0.2, newValue))) }
    }
    var jupiterSize: Double {
        get { d("jupiter_size", default: 0.016, lo: 0, hi: 0.2) }
        set { set("jupiter_size", max(0, min(0.2, newValue))) }
    }
    var saturnSize: Double {
        get { d("saturn_size", default: 0.01349, lo: 0, hi: 0.2) }
        set { set("saturn_size", max(0, min(0.2, newValue))) }
    }
    var uranusSize: Double {
        get { d("uranus_size", default: 0.00584, lo: 0, hi: 0.2) }
        set { set("uranus_size", max(0, min(0.2, newValue))) }
    }
    var neptuneSize: Double {
        get { d("neptune_size", default: 0.00566, lo: 0, hi: 0.2) }
        set { set("neptune_size", max(0, min(0.2, newValue))) }
    }
    var plutoSize: Double {
        get { d("pluto_size", default: 0.000272, lo: 0, hi: 0.2) }
        set { set("pluto_size", max(0, min(0.2, newValue))) }
    }

    // MARK: - Debug

    var debugOverlayEnabled: Bool {
        get { b("debug_overlay_enabled", default: false) }
        set { set("debug_overlay_enabled", newValue) }
    }

    var debugMoonColors: Bool {
        get { b("debug_moon_colors", default: false) }
        set { set("debug_moon_colors", newValue) }
    }

    // MARK: - TOML serialisation
    //
    // Emits only the keys the options panel controls.  Keys omitted here
    // keep their starry-core Config::default() values.  Key names and
    // value formats must match PartialConfig in toml_config.rs exactly.

    func tomlString() -> String {
        var lines: [String] = []

        func f(_ key: String, _ v: Double) { lines.append("\(key) = \(v)") }
        func b(_ key: String, _ v: Bool)   { lines.append("\(key) = \(v)") }
        func i(_ key: String, _ v: Int)    { lines.append("\(key) = \(v)") }
        func q(_ key: String, _ v: String) { lines.append("\(key) = \"\(v)\"") }

        f("stars_fraction",            starsFraction)
        f("lights_fraction",           lightsFraction)
        f("clear_interval_s",          clearIntervalS)
        f("building_height_pct_max",   buildingHeightPctMax)
        b("shooting_stars_enabled",    shootingStarsEnabled)
        f("shooting_stars_avg_seconds", shootingStarsAvgSeconds)
        b("satellites_enabled",        satellitesEnabled)
        b("moon_enabled",              moonEnabled)
        f("moon_diameter_percent",     moonDiameterPercent)
        f("moon_traversal_seconds",    moonTraversalSeconds)
        i("moon_terminator_mode",      moonTerminatorMode)
        f("moon_bright_brightness",    moonBrightBrightness)
        f("moon_dark_brightness",      moonDarkBrightness)
        b("moon_phase_override_enabled", moonPhaseOverrideEnabled)
        f("moon_phase_override_value", moonPhaseOverrideValue)
        b("planets_enabled",           planetsEnabled)
        b("planet_moons_enabled",      planetMoonsEnabled)
        q("planet_below_horizon_behavior", planetBelowHorizonBehavior)
        q("planet_phase_mode",         planetPhaseMode)
        q("saturn_ring_style",         saturnRingStyle)
        f("mercury_size",              mercurySize)
        f("venus_size",                venusSize)
        f("mars_size",                 marsSize)
        f("jupiter_size",              jupiterSize)
        f("saturn_size",               saturnSize)
        f("uranus_size",               uranusSize)
        f("neptune_size",              neptuneSize)
        f("pluto_size",                plutoSize)
        b("debug_overlay_enabled",     debugOverlayEnabled)
        b("debug_moon_colors",         debugMoonColors)

        return lines.joined(separator: "\n")
    }
}
