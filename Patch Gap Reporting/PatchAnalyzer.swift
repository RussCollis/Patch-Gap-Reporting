import Foundation

/// Where an installed app stands against Patch Management and App Installers.
nonisolated enum PatchStatus: String, CaseIterable, Identifiable, Sendable {
    case notPatchedAvailable = "Not patched – title available"
    case notPatchedNoTitle = "Not patched – no Jamf title"
    /// A patch title exists, so Jamf reports versions, but no enabled patch policy updates the app.
    case reportingOnly = "Reporting only"
    /// An enabled patch policy or App Installer deployment keeps the app up to date.
    case patched = "Patched"

    var id: String { rawValue }

    var isPatched: Bool { self == .patched }
    var hasNoTitle: Bool { self == .notPatchedAvailable || self == .notPatchedNoTitle }
}

/// Which kind of Jamf patch definition covers (or could cover) an app.
nonisolated enum DefinitionKind: String, Sendable {
    /// The configured patch title is a Combined Definition.
    case combined = "Combined Definition"
    /// The configured title is version-specific but a Combined Definition exists.
    case versionSpecificCombinedAvailable = "Version-specific – Combined available"
    /// The configured title is the only definition Jamf offers for the app.
    case standard = "Standard (no Combined offered)"
    /// Not configured yet; a Combined Definition is available to add.
    case combinedAvailable = "Combined available"
    /// Not configured yet; only a version-specific or standard definition is available.
    case standardAvailable = "Standard available"
    /// Patched through a Jamf App Catalog App Installer rather than a patch definition.
    case appInstaller = "App Installer"
    case none = ""

    var needsCombined: Bool { self == .versionSpecificCombinedAvailable }
}

/// One installed app, grouped across every computer that has it.
nonisolated struct AppPatchRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIDs: [String]
    let versions: [String]
    let computerCount: Int
    let status: PatchStatus
    let definition: DefinitionKind
    /// The Patch Management title(s) or App Installer that Jamf already has for the app.
    let jamfTitle: String
    /// The patch title to add (or switch to), always the Combined Definition where one exists.
    let recommendedPatchTitle: String
    /// A Jamf App Catalog App Installer that could deploy and patch the app.
    let appInstallerTitle: String

    var bundleIDText: String { bundleIDs.joined(separator: ", ") }
    var versionText: String { versions.joined(separator: ", ") }
    var statusText: String { status.rawValue }
    var definitionText: String { definition.rawValue }
}

nonisolated struct AnalysisOptions: Sendable {
    var hideAppleApps = true
    var applicationsFolderOnly = true
}

nonisolated enum PatchAnalyzer {
    /// Builds one row per installed app (grouped by normalised name).
    /// - Parameter patchPolicies: `nil` when the policies couldn't be read; configured titles then count as patched.
    static func analyse(
        installed: [(computerID: String, app: InventoryApplication)],
        configurations: [PatchTitleConfiguration],
        patchPolicies: [PatchPolicy]?,
        availableTitles: [PatchAvailableTitle],
        appInstallerTitles: [AppInstallerTitle],
        appInstallerDeployments: [AppInstallerDeployment],
        options: AnalysisOptions
    ) -> [AppPatchRow] {
        // Group installed apps by normalised name.
        struct Group {
            var name: String
            var bundleIDs = Set<String>()
            var versions = Set<String>()
            var computers = Set<String>()
        }
        var groups: [String: Group] = [:]
        for (computerID, app) in installed {
            if options.hideAppleApps, app.bundleId?.hasPrefix("com.apple.") == true { continue }
            if options.applicationsFolderOnly, let path = app.path, !path.hasPrefix("/Applications/") { continue }

            let key = normalise(app.name)
            guard !key.isEmpty else { continue }
            var group = groups[key] ?? Group(name: displayName(app.name))
            if let bundleID = app.bundleId, !bundleID.isEmpty { group.bundleIDs.insert(bundleID) }
            if let version = app.version, !version.isEmpty { group.versions.insert(version) }
            group.computers.insert(computerID)
            groups[key] = group
        }

        let configsByKey = Dictionary(grouping: configurations) { normalise($0.titleName) }
        let catalogByKey = Dictionary(grouping: availableTitles) { normalise($0.appName) }
        let combinedNameIDs = Set(availableTitles.filter(\.isCombinedDefinition).map(\.nameId))
        let installersByKey = Dictionary(grouping: appInstallerTitles) { normalise($0.titleName) }
        var installersByBundle: [String: AppInstallerTitle] = [:]
        for title in appInstallerTitles {
            if let bundleID = title.bundleId?.lowercased(), !bundleID.isEmpty { installersByBundle[bundleID] = title }
        }
        let deployedTitleIDs = Set(appInstallerDeployments.filter { $0.enabled != false }.compactMap(\.appTitleId))
        let activePolicyCounts = patchPolicies.map { policies in
            Dictionary(grouping: policies.filter(\.enabled).compactMap(\.softwareTitleConfigurationId)) { $0 }.mapValues(\.count)
        }

        /// A configuration is combined if Jamf says so in its name or publisher, or its catalogue entry is combined.
        func isCombined(_ config: PatchTitleConfiguration) -> Bool {
            config.isCombinedDefinition || config.softwareTitleNameId.map(combinedNameIDs.contains) == true
        }

        return groups.map { key, group in
            let combined = catalogByKey[key]?.first(where: \.isCombinedDefinition)
            let recommended = combined ?? preferredTitle(catalogByKey[key] ?? [])

            // Prefer a bundle ID match for App Installers; names differ more often than bundle IDs.
            let installer = group.bundleIDs.lazy.compactMap { installersByBundle[$0.lowercased()] }.first
                ?? installersByKey[key]?.first
            let installerDeployed = installer.map { deployedTitleIDs.contains($0.id) } ?? false

            let status: PatchStatus
            let definition: DefinitionKind
            var jamfTitle = ""
            var recommendedName = ""

            if let configs = configsByKey[key], !configs.isEmpty {
                let activePolicies = configs.reduce(0) { $0 + (activePolicyCounts?[$1.id] ?? 0) }
                let policyNote = activePolicyCounts == nil ? "" : " (\(activePolicies) active polic\(activePolicies == 1 ? "y" : "ies"))"
                jamfTitle = configs.map(\.titleName).joined(separator: ", ") + policyNote

                status = activePolicyCounts == nil || activePolicies > 0 || installerDeployed ? .patched : .reportingOnly

                if configs.contains(where: isCombined) {
                    definition = .combined
                } else if let combined {
                    definition = .versionSpecificCombinedAvailable
                    recommendedName = combined.displayName
                } else {
                    definition = .standard
                }
            } else if let installer, installerDeployed {
                status = .patched
                definition = .appInstaller
                jamfTitle = "App Installer: \(installer.titleName)"
            } else {
                status = recommended != nil || installer != nil ? .notPatchedAvailable : .notPatchedNoTitle
                definition = combined != nil ? .combinedAvailable : (recommended != nil ? .standardAvailable : .none)
                recommendedName = recommended?.displayName ?? ""
            }

            return AppPatchRow(
                id: key,
                name: group.name,
                bundleIDs: group.bundleIDs.sorted(),
                versions: group.versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending },
                computerCount: group.computers.count,
                status: status,
                definition: definition,
                jamfTitle: jamfTitle,
                recommendedPatchTitle: recommendedName,
                appInstallerTitle: installerDeployed ? "" : (installer?.titleName ?? "")
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reduces an app or title name to a matching key, so that "Adobe Photoshop 2025.app",
    /// "Adobe Photoshop (Combined Definition)" and "Adobe Photoshop 2024" all become "adobe photoshop".
    static func normalise(_ name: String) -> String {
        var value = name.lowercased()
        if value.hasSuffix(".app") { value.removeLast(4) }
        value = value.replacingOccurrences(of: "(combined definition)", with: " ")

        // Collapse punctuation to spaces, then drop version or year tokens such as "8", "2025" or "16.2".
        var tokens = value
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
        // Version numbers can also sit mid-name ("Ableton Live 12 Suite"), so drop every purely numeric token
        // as long as a word remains.
        let words = tokens.filter { !$0.allSatisfy({ $0.isNumber || $0 == "." }) }
        if !words.isEmpty { tokens = words }
        return tokens.joined(separator: " ")
    }

    private static func displayName(_ name: String) -> String {
        name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Falls back to the shortest (least version-specific) title when there is no Combined Definition.
    private static func preferredTitle(_ titles: [PatchAvailableTitle]) -> PatchAvailableTitle? {
        titles.min { $0.appName.count < $1.appName.count }
    }

    /// CSV export of the given rows.
    static func csv(for rows: [AppPatchRow]) -> String {
        let header = ["App", "Status", "Definition", "Computers", "Versions", "Bundle IDs", "In Jamf as", "Recommended patch title", "App Installer available"]
        let lines = rows.map { row in
            [row.name, row.statusText, row.definitionText, String(row.computerCount), row.versionText, row.bundleIDText,
             row.jamfTitle, row.recommendedPatchTitle, row.appInstallerTitle]
        }
        return ([header] + lines)
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
