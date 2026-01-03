import Foundation

/// Microphone entry for priority list
struct MicrophoneEntry: Codable, Equatable {
    let uid: String
    let name: String
}

/// App entry for exclusion list
struct AppEntry: Codable, Equatable {
    let bundleID: String
    let name: String
}

/// Unified configuration for sck-cli
/// Stored at ~/.sck-cli.json
struct Config: Codable {
    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".sck-cli.json")

    /// Ordered list of microphones (first = highest priority)
    var microphonePriority: [MicrophoneEntry]

    /// Apps to exclude from screen capture
    var excludedApps: [AppEntry]

    /// Exclude private/incognito browser windows (Safari, Chrome, Firefox)
    var excludePrivateBrowsing: Bool

    /// Default exclusions written on first run
    static let defaultExclusions: [AppEntry] = [
        AppEntry(bundleID: "com.1password.1password", name: "1Password"),
        AppEntry(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppEntry(bundleID: "com.agilebits.onepassword-osx", name: "1Password (legacy)")
    ]

    init(microphonePriority: [MicrophoneEntry] = [], excludedApps: [AppEntry] = [], excludePrivateBrowsing: Bool = true) {
        self.microphonePriority = microphonePriority
        self.excludedApps = excludedApps
        self.excludePrivateBrowsing = excludePrivateBrowsing
    }

    /// Custom decoder for backward compatibility with configs missing excludePrivateBrowsing
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        microphonePriority = try container.decodeIfPresent([MicrophoneEntry].self, forKey: .microphonePriority) ?? []
        excludedApps = try container.decodeIfPresent([AppEntry].self, forKey: .excludedApps) ?? []
        excludePrivateBrowsing = try container.decodeIfPresent(Bool.self, forKey: .excludePrivateBrowsing) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case microphonePriority
        case excludedApps
        case excludePrivateBrowsing
    }

    /// Loads config from ~/.sck-cli.json
    /// Returns empty config if file doesn't exist or is invalid
    static func load() -> Config {
        guard FileManager.default.fileExists(atPath: defaultPath.path) else {
            return Config()
        }

        do {
            let data = try Data(contentsOf: defaultPath)
            let config = try JSONDecoder().decode(Config.self, from: data)
            return config
        } catch {
            fputs("[WARN] Failed to load config: \(error.localizedDescription)\n", stderr)
            return Config()
        }
    }

    /// Loads config or creates with defaults if missing
    /// Also migrates old config files if present
    static func loadOrCreateDefault() -> Config {
        // Check for migration from old config format
        migrateOldConfigs()

        if FileManager.default.fileExists(atPath: defaultPath.path) {
            return load()
        }

        // Create default config
        var config = Config()
        config.excludedApps = defaultExclusions

        do {
            try config.save()
            fputs("Created default config at \(defaultPath.path)\n", stderr)
        } catch {
            fputs("[WARN] Failed to save default config: \(error.localizedDescription)\n", stderr)
        }

        return config
    }

    /// Saves config to ~/.sck-cli.json
    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.defaultPath, options: .atomic)
    }

    /// Migrates old .sck-cli-mics.json files to unified config
    private static func migrateOldConfigs() {
        // Check current directory for old mic config
        let oldMicConfig = URL(fileURLWithPath: ".sck-cli-mics.json")
        if FileManager.default.fileExists(atPath: oldMicConfig.path) {
            do {
                let data = try Data(contentsOf: oldMicConfig)
                if let oldConfig = try? JSONDecoder().decode(OldMicConfig.self, from: data) {
                    var newConfig = load()
                    newConfig.microphonePriority = oldConfig.priorities
                    if newConfig.excludedApps.isEmpty {
                        newConfig.excludedApps = defaultExclusions
                    }
                    try newConfig.save()
                    try FileManager.default.removeItem(at: oldMicConfig)
                    fputs("Migrated mic config to \(defaultPath.path)\n", stderr)
                }
            } catch {
                fputs("[WARN] Failed to migrate old mic config: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    // MARK: - Microphone Methods

    /// Selects the highest priority microphone that is currently available
    func selectBestMicrophone(from available: [AudioInputDevice]) -> AudioInputDevice? {
        let availableUIDs = Set(available.map { $0.uid })

        for entry in microphonePriority {
            if availableUIDs.contains(entry.uid) {
                return available.first(where: { $0.uid == entry.uid })
            }
        }

        return nil
    }

    /// Adds a microphone to the priority list
    mutating func addMicrophone(_ device: AudioInputDevice) -> Bool {
        guard !microphonePriority.contains(where: { $0.uid == device.uid }) else {
            return false
        }
        microphonePriority.append(MicrophoneEntry(uid: device.uid, name: device.name))
        return true
    }

    /// Removes a microphone from the priority list
    mutating func removeMicrophone(uid: String) -> Bool {
        let countBefore = microphonePriority.count
        microphonePriority.removeAll(where: { $0.uid == uid })
        return microphonePriority.count < countBefore
    }

    /// Sets microphone priority position (1-indexed)
    mutating func setMicrophonePriority(uid: String, position: Int) -> Bool {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else {
            return false
        }

        let zeroIndexed = position - 1
        guard zeroIndexed >= 0 && zeroIndexed < microphonePriority.count else {
            return false
        }

        let entry = microphonePriority.remove(at: index)
        microphonePriority.insert(entry, at: zeroIndexed)
        return true
    }

    /// Returns priority position (1-indexed) for a mic UID
    func microphonePriorityPosition(for uid: String) -> Int? {
        guard let index = microphonePriority.firstIndex(where: { $0.uid == uid }) else {
            return nil
        }
        return index + 1
    }

    // MARK: - App Exclusion Methods

    /// Checks if an app is excluded
    func isAppExcluded(bundleID: String) -> Bool {
        excludedApps.contains(where: { $0.bundleID == bundleID })
    }

    /// Adds an app to the exclusion list
    mutating func excludeApp(bundleID: String, name: String) -> Bool {
        guard !excludedApps.contains(where: { $0.bundleID == bundleID }) else {
            return false
        }
        excludedApps.append(AppEntry(bundleID: bundleID, name: name))
        return true
    }

    /// Removes an app from the exclusion list
    mutating func includeApp(bundleID: String) -> Bool {
        let countBefore = excludedApps.count
        excludedApps.removeAll(where: { $0.bundleID == bundleID })
        return excludedApps.count < countBefore
    }
}

/// Old config format for migration
private struct OldMicConfig: Codable {
    let priorities: [MicrophoneEntry]
}
