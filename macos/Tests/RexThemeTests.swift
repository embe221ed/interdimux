import AppKit

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

@main
struct RexThemeTests {
    static func main() {
        do { try run() }
        catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        func rgb(_ r: Double, _ g: Double, _ b: Double, space: String = "srgb") -> [String: Any] {
            ["red": r, "green": g, "blue": b, "alpha": 1, "colorSpace": space]
        }
        func red(_ color: NSColor) -> CGFloat { color.usingColorSpace(.sRGB)!.redComponent }
        let dark: [String: Any] = ["id": "custom-dark", "name": "Imported Dark", "palette": [
            "background": rgb(0.1, 0.12, 0.14), "foreground": rgb(0.9, 0.88, 0.86), "cursor": rgb(0.8, 0.4, 0.2)]]
        let light: [String: Any] = ["id": "custom-light", "name": "Imported Light", "palette": [
            "background": rgb(0.95, 0.94, 0.92), "foreground": rgb(0.2, 0.18, 0.16), "cursor": rgb(0.3, 0.5, 0.7)]]
        var preferences: [String: Any] = ["Workspace.lightThemeID": "custom-light", "Workspace.darkThemeID": "custom-dark",
            "Workspace.customThemes": try JSONSerialization.data(withJSONObject: [dark, light])]
        func resolve(_ system: Bool) -> RexTheme {
            RexThemeReader.resolve(preferences: preferences, bundledThemes: [], systemIsDark: system)
        }
        try check(resolve(false).name == "Imported Light" && !resolve(false).isDark, "Auto did not select light palette")
        try check(resolve(true).name == "Imported Dark" && resolve(true).isDark, "Auto did not select dark palette")
        preferences["Workspace.appearance"] = "system"
        try check(resolve(false).name == "Imported Light" && resolve(true).name == "Imported Dark", "Explicit system appearance did not track both modes")
        preferences["Workspace.appearance"] = "dark"
        try check(resolve(false).isDark && resolve(false).name == "Imported Dark", "Rex dark override followed light system")
        preferences["Workspace.appearance"] = "light"
        let lightTheme = resolve(true)
        try check(!lightTheme.isDark && lightTheme.name == "Imported Light", "Rex light override followed dark system")
        try check(abs(red(lightTheme.background) - 0.95) < 0.0001 && abs(red(lightTheme.accent) - 0.3) < 0.0001,
                  "Imported background or cursor accent changed")
        var editedLight = light
        editedLight["palette"] = ["background": rgb(0.85, 0.84, 0.82), "foreground": rgb(0.2, 0.18, 0.16), "cursor": rgb(0.3, 0.5, 0.7)]
        preferences["Workspace.customThemes"] = try JSONSerialization.data(withJSONObject: [dark, editedLight])
        try check(abs(red(resolve(true).background) - 0.85) < 0.0001, "Edited custom palette retained its cached colors")

        // Custom IDs override catalog IDs; built-in semantic colors preserve P3.
        let builtin: [String: Any] = ["id": "builtin", "name": "Builtin", "semantic": [
            "canvas": rgb(0.3, 0.2, 0.1, space: "display-p3"), "content": rgb(0.8, 0.8, 0.8),
            "accent": rgb(0.4, 0.7, 0.6, space: "display-p3")]]
        preferences["Workspace.lightThemeID"] = "builtin"
        let builtinTheme = RexThemeReader.resolve(preferences: preferences, bundledThemes: [builtin], systemIsDark: true)
        try check(builtinTheme.name == "Builtin" && !builtinTheme.isDark, "Built-in theme resolution failed")
        try check(builtinTheme.background.colorSpace == .displayP3, "Wide-gamut built-in background lost its color space")
        try check(builtinTheme.accent.colorSpace == .displayP3, "Wide-gamut accent lost its color space")
        let hexTheme: [String: Any] = ["id": "hex", "source": ["background": "#102030", "foreground": "#e0e0e0", "cursor": "#4080c0"]]
        preferences["Workspace.lightThemeID"] = "hex"
        let hex = RexThemeReader.resolve(preferences: preferences, bundledThemes: [hexTheme], systemIsDark: false)
        try check(abs(red(hex.background) - 16.0 / 255) < 0.0001, "Hex palette fallback failed")

        preferences["Workspace.customThemes"] = Data("malformed".utf8)
        preferences["Workspace.lightThemeID"] = "missing"
        try check(resolve(false).name == "System" && !resolve(false).isDark, "Unknown/malformed palette did not fall back safely")
        preferences["Workspace.appearance"] = "future-mode"
        try check(resolve(true).isDark && !resolve(false).isDark, "Unknown appearance did not follow system")
        let bad: [String: Any] = ["id": "missing", "palette": ["background": rgb(2, 0, 0), "foreground": rgb(0, 0, 0)]]
        try check(RexThemeReader.resolve(preferences: preferences, bundledThemes: [bad], systemIsDark: false).name == "System",
                  "Invalid color components were accepted")
        let fallbackLight = RexThemeReader.resolve(preferences: [:], bundledThemes: [], systemIsDark: false)
        let fallbackDark = RexThemeReader.resolve(preferences: [:], bundledThemes: [], systemIsDark: true)
        try check(red(fallbackLight.background) > red(fallbackDark.background), "System fallback stayed fixed across appearances")
        let defaults: [[String: Any]] = [
            ["id": "merino-light", "name": "Merino Light", "source": ["background": "#f0f0f0", "foreground": "#202020", "cursor": "#2040c0"]],
            ["id": "merino-dark", "name": "Merino Dark", "source": ["background": "#101010", "foreground": "#e0e0e0", "cursor": "#6080f0"]]
        ]
        try check(RexThemeReader.resolve(preferences: [:], bundledThemes: defaults, systemIsDark: false).name == "Merino Light",
                  "Absent light theme selection did not use Rex's bundled default")
        try check(RexThemeReader.resolve(preferences: [:], bundledThemes: defaults, systemIsDark: true).name == "Merino Dark",
                  "Absent dark theme selection did not use Rex's bundled default")
        try check(RexThemeReader.resolve(preferences: ["Workspace.appearance": "light"], bundledThemes: defaults, systemIsDark: true).name == "Merino Light",
                  "Absent theme selection ignored the Rex appearance override")
        for badID: Any in ["unknown", "", 42] {
            try check(RexThemeReader.resolve(preferences: ["Workspace.lightThemeID": badID], bundledThemes: defaults, systemIsDark: false).name == "System",
                      "Malformed/unknown selected theme ID was mistaken for an absent default")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("interdimux-theme-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let prefsURL = directory.appendingPathComponent("preferences.plist")
        let catalogURL = directory.appendingPathComponent("themes.json")
        func write(_ mode: String) throws {
            let prefs: [String: Any] = ["Workspace.appearance": mode, "Workspace.lightThemeID": "builtin", "Workspace.darkThemeID": "builtin"]
            let data = try PropertyListSerialization.data(fromPropertyList: prefs, format: .binary, options: 0)
            try data.write(to: prefsURL, options: .atomic)
        }
        try JSONSerialization.data(withJSONObject: [builtin]).write(to: catalogURL)
        try write("light")
        let initial = RexThemeReader.read(preferencesURL: prefsURL, catalogURL: catalogURL, systemIsDark: true)
        try check(!initial.isDark && initial.name == "Builtin", "File-backed initial resolution failed")
        let oldDate = try FileManager.default.attributesOfItem(atPath: prefsURL.path)[.modificationDate] as! Date
        try write("dark")
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: prefsURL.path)
        try check(RexThemeReader.read(preferencesURL: prefsURL, catalogURL: catalogURL, systemIsDark: false).isDark,
                  "Atomic preference replacement reused stale cached appearance")
        var changedBuiltin = builtin
        changedBuiltin["name"] = "Changed Builtin"
        try JSONSerialization.data(withJSONObject: [changedBuiltin]).write(to: catalogURL, options: .atomic)
        try check(RexThemeReader.read(preferencesURL: prefsURL, catalogURL: catalogURL, systemIsDark: false).name == "Changed Builtin",
                  "Changed theme resource reused cached palette")
        try FileManager.default.removeItem(at: prefsURL)
        try check(RexThemeReader.read(preferencesURL: prefsURL, catalogURL: catalogURL, systemIsDark: false).name == "System",
                  "Removed preferences retained stale appearance")
        print("Theme reader checks passed: Rex overrides/Auto, custom edits, built-in/default palettes, wide gamut, malformed fallbacks and file replacement")
    }
}
