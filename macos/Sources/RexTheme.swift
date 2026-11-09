import AppKit

/// The local Rex app has no theme getter in its client actions. Its persisted
/// appearance and palette choices are read without changing the Rex domain.
struct RexTheme: Equatable {
    let isDark: Bool
    let name: String
    let background: NSColor
    let foreground: NSColor
    let accent: NSColor
}

enum RexThemeReader {
    private struct Stamp: Equatable {
        let size: UInt64
        let inode: UInt64
        let modified: Date
    }

    private struct CachedJSON {
        var stamp: Stamp?
        var value: Any?

        mutating func read(_ url: URL, propertyList: Bool) -> Any? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let modified = attributes[.modificationDate] as? Date else {
                stamp = nil
                value = nil
                return nil
            }
            let next = Stamp(size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                             inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                             modified: modified)
            if stamp == next { return value }
            guard let data = try? Data(contentsOf: url),
                  let decoded = propertyList
                    ? try? PropertyListSerialization.propertyList(from: data, format: nil)
                    : try? JSONSerialization.jsonObject(with: data) else {
                // Keep retrying a file that was temporarily unreadable during
                // replacement, rather than treating its stamp as authoritative.
                return nil
            }
            stamp = next
            value = decoded
            return decoded
        }
    }

    private static var preferenceFiles: [URL: CachedJSON] = [:]
    private static var catalogFiles: [URL: CachedJSON] = [:]
    private static var customData: Data?
    private static var customEntries: [[String: Any]] = []

    static func read(systemIsDark: Bool) -> RexTheme {
        let domain = "com.superlogical.rex" as CFString
        // Synchronize a read-only domain to invalidate this process's cached
        // values and obtain Rex's latest daemon-backed choices, even before
        // cfprefsd has flushed them to its plist. No preference is set here.
        CFPreferencesAppSynchronize(domain)
        let keys = ["Workspace.appearance", "Workspace.lightThemeID", "Workspace.darkThemeID", "Workspace.customThemes"] as CFArray
        let preferences = CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
        let catalog = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.superlogical.rex")?
            .appendingPathComponent("Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json")
        let themes = catalog.map { catalogFiles[$0, default: CachedJSON()].read($0, propertyList: false) as? [[String: Any]] ?? [] } ?? []
        return resolve(preferences: preferences, bundledThemes: themes, systemIsDark: systemIsDark)
    }

    /// Read the files each time they change, including atomic replacements.
    /// Cached decoding makes visible-window polling cheap and avoids stale
    /// cross-process UserDefaults caches after Rex switches its appearance.
    static func read(preferencesURL: URL, catalogURL: URL?, systemIsDark: Bool) -> RexTheme {
        let preferences = preferenceFiles[preferencesURL, default: CachedJSON()]
            .read(preferencesURL, propertyList: true) as? [String: Any] ?? [:]
        let catalog: [[String: Any]]
        if let url = catalogURL {
            catalog = catalogFiles[url, default: CachedJSON()]
                .read(url, propertyList: false) as? [[String: Any]] ?? []
        } else {
            catalog = []
        }
        return resolve(preferences: preferences, bundledThemes: catalog, systemIsDark: systemIsDark)
    }

    static func resolve(preferences: [String: Any], bundledThemes: [[String: Any]], systemIsDark: Bool) -> RexTheme {
        let isDark: Bool
        switch (preferences["Workspace.appearance"] as? String)?.lowercased() {
        case "light": isDark = false
        case "dark": isDark = true
        default: isDark = systemIsDark
        }
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        func fixed(_ color: NSColor) -> NSColor {
            var result = color
            appearance.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB) ?? color
            }
            return result
        }
        let fallback = RexTheme(isDark: isDark, name: "System",
                                background: fixed(.windowBackgroundColor), foreground: fixed(.labelColor),
                                accent: fixed(.controlAccentColor))
        let selection = preferences[isDark ? "Workspace.darkThemeID" : "Workspace.lightThemeID"]
        let id: String
        if selection == nil {
            // Rex's Default choice uses these bundled palettes even when it
            // has never persisted an explicit theme selection for this mode.
            id = isDark ? "merino-dark" : "merino-light"
        } else if let selectedID = selection as? String, !selectedID.isEmpty {
            id = selectedID
        } else {
            return fallback
        }
        let custom: [[String: Any]]
        if let data = preferences["Workspace.customThemes"] as? Data {
            if data != customData {
                customData = data
                customEntries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            }
            custom = customEntries
        } else {
            custom = preferences["Workspace.customThemes"] as? [[String: Any]] ?? []
        }
        guard let theme = (custom + bundledThemes).first(where: { $0["id"] as? String == id }) else { return fallback }

        // Built-in themes already contain Rex's resolved UI colors. Imported
        // custom themes retain their terminal palette; Rex uses its cursor as
        // the accent. Preserve wide-gamut colors when they are available.
        let semantic = theme["semantic"] as? [String: Any] ?? [:]
        let palette = theme["palette"] as? [String: Any] ?? [:]
        let source = theme["source"] as? [String: Any] ?? [:]
        guard let background = color(semantic["canvas"]) ?? color(palette["background"]) ?? color(source["background"]),
              let foreground = color(semantic["content"]) ?? color(palette["foreground"]) ?? color(source["foreground"]) else {
            return fallback
        }
        let accent = color(semantic["accent"]) ?? color(palette["cursor"]) ?? color(source["cursor"]) ?? fallback.accent
        return RexTheme(isDark: isDark, name: theme["name"] as? String ?? id,
                        background: background, foreground: foreground, accent: accent)
    }

    private static func color(_ value: Any?) -> NSColor? {
        if let values = value as? [String: Any],
           let red = values["red"] as? Double,
           let green = values["green"] as? Double,
           let blue = values["blue"] as? Double {
            let alpha = values["alpha"] as? Double ?? 1
            guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
            if values["colorSpace"] as? String == "display-p3" {
                return NSColor(displayP3Red: red, green: green, blue: blue, alpha: alpha)
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        if let hex = value as? String, hex.hasPrefix("#"), hex.count == 7,
           let rgb = UInt32(hex.dropFirst(), radix: 16) {
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        }
        return nil
    }
}
