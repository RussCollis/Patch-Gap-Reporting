import Foundation

/// Where an installed app stands against Patch Management and App Installers.
nonisolated enum PatchStatus: String, CaseIterable, Identifiable, Sendable {
    case notPatchedAvailable = "Not patched – title available"
    case notPatchedNoTitle = "Not patched – no Jamf title"
    /// A patch title exists, so Jamf reports versions, but no enabled patch policy updates the app.
    case reportingOnly = "Not patched – reporting"
    /// An enabled patch policy or App Installer deployment keeps the app up to date.
    case patched = "Patched"

    var id: String { rawValue }

    var isPatched: Bool { self == .patched }
    var isNotPatched: Bool { self != .patched }
}

/// How an app is handled through a Jamf Title Editor custom title, as set by the admin.
nonisolated enum TitleEditorMode: String, CaseIterable, Identifiable, Sendable {
    case patched = "Title Editor Patched"
    case reporting = "Title Editor Reporting"

    var id: String { rawValue }
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
    /// Marked by the admin as patched through a Jamf Title Editor custom title.
    case titleEditor = "Title Editor"
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
    /// A configured Jamf patch title that no inventory app matched, so it has no bundle IDs or versions.
    var isJamfTitleOnly: Bool { id.hasPrefix("title:") }
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
        patchSummaries: [String: PatchSummary] = [:],
        availableTitles: [PatchAvailableTitle],
        appInstallerTitles: [AppInstallerTitle],
        appInstallerDeployments: [AppInstallerDeployment],
        options: AnalysisOptions,
        titleEditor: [String: TitleEditorMode] = [:]
    ) -> [AppPatchRow] {
        // Group installed apps. Inventory sometimes reports a stray name against a bundle ID
        // (e.g. Self Service+ listed as "Microsoft Outlook"), so first collect every bundle ID,
        // name it by what most computers call it, then merge bundle IDs and bundle-less apps by that name.
        struct Group {
            var name: String
            var bundleIDs = Set<String>()
            var versions = Set<String>()
            var computers = Set<String>()

            mutating func merge(_ other: Group) {
                bundleIDs.formUnion(other.bundleIDs)
                versions.formUnion(other.versions)
                computers.formUnion(other.computers)
            }
        }
        struct BundleTally {
            var nameCounts: [String: Int] = [:]
            var group = Group(name: "")
        }
        var bundles: [String: BundleTally] = [:]
        var bundleless: [String: Group] = [:]
        for (computerID, app) in installed {
            if options.hideAppleApps, app.bundleId?.hasPrefix("com.apple.") == true { continue }
            if options.applicationsFolderOnly, let path = app.path, !path.hasPrefix("/Applications/") { continue }

            let name = displayName(app.name)
            guard !normalise(name).isEmpty else { continue }
            if let bundleID = app.bundleId, !bundleID.isEmpty {
                let bundleKey = bundleID.lowercased()
                var tally = bundles[bundleKey] ?? BundleTally()
                tally.nameCounts[name, default: 0] += 1
                tally.group.bundleIDs.insert(bundleID)
                if let version = app.version, !version.isEmpty { tally.group.versions.insert(version) }
                tally.group.computers.insert(computerID)
                bundles[bundleKey] = tally
            } else {
                let key = normalise(name)
                var group = bundleless[key] ?? Group(name: name)
                if let version = app.version, !version.isEmpty { group.versions.insert(version) }
                group.computers.insert(computerID)
                bundleless[key] = group
            }
        }

        var groups: [String: Group] = [:]
        for tally in bundles.values {
            // Most common name wins; ties go to the alphabetically first so results are stable.
            let name = tally.nameCounts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? ""
            var group = tally.group
            group.name = name
            let key = normalise(name)
            if var existing = groups[key] {
                existing.merge(group)
                groups[key] = existing
            } else {
                groups[key] = group
            }
        }
        for (key, group) in bundleless {
            if var existing = groups[key] {
                existing.merge(group)
                groups[key] = existing
            } else {
                groups[key] = group
            }
        }

        // A configuration can be found by its catalogue title name or its admin-given display name;
        // Title Editor titles often differ between the two (e.g. display name "Global Protect").
        func index(_ keys: (PatchTitleConfiguration) -> [String]) -> [String: [PatchTitleConfiguration]] {
            var result: [String: [PatchTitleConfiguration]] = [:]
            for config in configurations {
                for key in Set(keys(config)) where !key.isEmpty { result[key, default: []].append(config) }
            }
            return result
        }
        let configsByKey = index { config in
            [config.softwareTitleName, config.displayName].compactMap { $0 }.map { compact(normalise($0)) }
        }
        let catalogByKey = Dictionary(grouping: availableTitles) { compact(normalise($0.appName)) }
        // Titles often carry the publisher ("Microsoft Windows App") where inventory doesn't ("Windows App"),
        // so also index them without it, as a fallback behind the exact name.
        let configsByShortKey = index { config in
            [config.softwareTitleName, config.displayName].compactMap { $0 }.map { compact(withoutPublisher(normalise($0), config.softwareTitlePublisher)) }
        }
        let catalogByShortKey = Dictionary(grouping: availableTitles) { compact(withoutPublisher(normalise($0.appName), $0.publisher)) }
        let combinedNameIDs = Set(availableTitles.filter(\.isCombinedDefinition).map(\.nameId))
        let installersByKey = Dictionary(grouping: appInstallerTitles) { compact(normalise($0.titleName)) }
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

        var matchedConfigIDs = Set<String>()
        var rows = groups.map { key, group in
            let matchKey = compact(key)
            // Prefer a bundle ID match for App Installers; names differ more often than bundle IDs.
            let installer = group.bundleIDs.sorted().lazy.compactMap { installersByBundle[$0.lowercased()] }.first
                ?? installersByKey[matchKey]?.first
            let installerDeployed = installer.map { deployedTitleIDs.contains($0.id) } ?? false

            // Try the app's own name, then the bundle-matched App Installer's name, then titles without their publisher.
            let installerKey = installer.map { compact(normalise($0.titleName)) }
            func lookup<T>(_ exact: [String: [T]], _ short: [String: [T]]) -> [T] {
                for candidate in [exact[matchKey], installerKey.flatMap { exact[$0] }, short[matchKey]] {
                    if let found = candidate, !found.isEmpty { return found }
                }
                return []
            }
            let catalog = lookup(catalogByKey, catalogByShortKey)
            let combined = catalog.first(where: \.isCombinedDefinition)
            let recommended = combined ?? preferredTitle(catalog)

            let status: PatchStatus
            let definition: DefinitionKind
            var jamfTitle = ""
            var recommendedName = ""

            // Every title matching the app's name or its App Installer's name, so a Jamf title and a
            // Title Editor title for the same app land on one row; publisher-less names are a last resort.
            var configs = [configsByKey[matchKey], installerKey.flatMap { configsByKey[$0] }]
                .compactMap { $0 }.flatMap { $0 }
            if configs.isEmpty { configs = configsByShortKey[matchKey] ?? [] }
            var seenConfigIDs = Set<String>()
            configs = configs.filter { seenConfigIDs.insert($0.id).inserted }
            matchedConfigIDs.formUnion(configs.map(\.id))
            if !configs.isEmpty {
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

        // Every configured title gets a row, even when no inventory app matched it by name (or the
        // inventory filters hid it), using Jamf's own install count from the patch summary.
        for config in configurations where !matchedConfigIDs.contains(config.id) {
            let activePolicies = activePolicyCounts?[config.id] ?? 0
            let policyNote = activePolicyCounts == nil ? "" : " (\(activePolicies) active polic\(activePolicies == 1 ? "y" : "ies"))"
            let combined = catalogByKey[compact(normalise(config.titleName))]?.first(where: \.isCombinedDefinition)
            let definition: DefinitionKind = isCombined(config) ? .combined : (combined != nil ? .versionSpecificCombinedAvailable : .standard)
            rows.append(AppPatchRow(
                id: "title:\(config.id)",
                name: config.displayName ?? config.titleName,
                bundleIDs: [],
                versions: [],
                computerCount: patchSummaries[config.id]?.computerCount ?? 0,
                status: activePolicyCounts == nil || activePolicies > 0 ? .patched : .reportingOnly,
                definition: definition,
                jamfTitle: config.titleName + policyNote,
                recommendedPatchTitle: definition == .versionSpecificCombinedAvailable ? (combined?.displayName ?? "") : "",
                appInstallerTitle: ""
            ))
        }

        // Apps the admin has marked as handled through Jamf Title Editor take the status they chose.
        rows = rows.map { row in
            guard let mode = titleEditor[row.id] else { return row }
            return AppPatchRow(
                id: row.id,
                name: row.name,
                bundleIDs: row.bundleIDs,
                versions: row.versions,
                computerCount: row.computerCount,
                status: mode == .patched ? .patched : .reportingOnly,
                definition: .titleEditor,
                jamfTitle: row.jamfTitle.isEmpty ? "Title Editor" : row.jamfTitle,
                recommendedPatchTitle: row.recommendedPatchTitle,
                appInstallerTitle: row.appInstallerTitle
            )
        }

        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

    /// A normalised key with its spaces removed, so "Global Protect" matches "GlobalProtect".
    private static func compact(_ key: String) -> String {
        key.replacingOccurrences(of: " ", with: "")
    }

    /// Drops a leading publisher name from a normalised title, e.g. "microsoft windows app" → "windows app".
    private static func withoutPublisher(_ key: String, _ publisher: String?) -> String {
        guard let publisher, let word = normalise(publisher).split(separator: " ").first else { return key }
        let prefix = word + " "
        return key.hasPrefix(prefix) && key.count > prefix.count ? String(key.dropFirst(prefix.count)) : key
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
