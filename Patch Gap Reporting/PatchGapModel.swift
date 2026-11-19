import Foundation
import Observation

/// Holds the Jamf Pro connection settings and the latest comparison results.
@Observable
final class PatchGapModel {
    // MARK: Connection settings (persisted; the secret lives in the keychain)

    var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? ""
    var authMethod: JamfAuthMethod = JamfAuthMethod(rawValue: UserDefaults.standard.string(forKey: "authMethod") ?? "") ?? .apiClient
    var identifier: String = UserDefaults.standard.string(forKey: "identifier") ?? ""
    var secret: String = ""

    var options = AnalysisOptions()

    // MARK: Results

    private(set) var rows: [AppPatchRow] = []
    private(set) var isLoading = false
    private(set) var progressMessage = ""
    private(set) var lastRefreshed: Date?
    private(set) var errorMessage: String?
    /// Non-fatal problems, such as a missing privilege for one optional endpoint.
    private(set) var warnings: [String] = []
    /// When the Jamf App Catalog App Installer title list was last read successfully, and how many titles it had.
    /// Persisted so the note survives relaunches.
    private(set) var titlesLastScanned: Date? = UserDefaults.standard.object(forKey: "titlesLastScanned") as? Date
    private(set) var titlesLastScannedCount: Int = UserDefaults.standard.integer(forKey: "titlesLastScannedCount")

    /// Raw data from the last fetch, kept so the filters can be changed without re-querying Jamf Pro.
    private var installed: [(computerID: String, app: InventoryApplication)] = []
    private var configurations: [PatchTitleConfiguration] = []
    /// `nil` when patch policies couldn't be read, so active vs reporting-only can't be told apart.
    private var patchPolicies: [PatchPolicy]?
    private var availableTitles: [PatchAvailableTitle] = []
    private var appInstallerTitles: [AppInstallerTitle] = []
    private var appInstallerDeployments: [AppInstallerDeployment] = []

    init() {
        secret = KeychainStore.secret(for: keychainAccount) ?? ""
    }

    var isConfigured: Bool { normalisedServerURL != nil && !identifier.isEmpty && !secret.isEmpty }

    private var keychainAccount: String { "\(authMethod.rawValue):\(identifier)" }

    private var normalisedServerURL: URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if !text.isEmpty, !text.lowercased().hasPrefix("http") { text = "https://" + text }
        guard let url = URL(string: text), url.host() != nil else { return nil }
        return url
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(authMethod.rawValue, forKey: "authMethod")
        defaults.set(identifier, forKey: "identifier")
        KeychainStore.setSecret(secret, for: keychainAccount)
    }

    // MARK: Fetching

    func refresh() async {
        guard let url = normalisedServerURL else {
            errorMessage = JamfError.invalidServerURL.localizedDescription
            return
        }
        let client = JamfClient(credentials: JamfCredentials(serverURL: url, method: authMethod, identifier: identifier, secret: secret))

        isLoading = true
        errorMessage = nil
        warnings = []
        defer { isLoading = false }

        do {
            progressMessage = "Reading computer inventory…"
            installed = try await client.fetchInventoryApplications { [weak self] done, total in
                self?.progressMessage = "Reading computer inventory… \(done) of \(total) computers"
            }

            progressMessage = "Reading Patch Management titles…"
            configurations = try await client.fetchPatchTitleConfigurations()

            progressMessage = "Reading patch policies…"
            patchPolicies = await optional("Patch policies (needs Read Patch Policies; titles shown as Patched without a Reporting only check)") {
                try await client.fetchPatchPolicies()
            }

            // The catalogue and App Installer lists improve recommendations but aren't essential.
            progressMessage = "Reading the Jamf patch catalogue…"
            availableTitles = await optional("Patch catalogue (needs Read Patch Internal Sources)") {
                try await client.fetchPatchAvailableTitles()
            } ?? []

            progressMessage = "Reading Jamf App Catalog App Installers…"
            if let titles = await optional("App Installer titles (needs Read App Installers)", { try await client.fetchAppInstallerTitles() }) {
                appInstallerTitles = titles
                recordTitlesScanned(count: titles.count)
            } else {
                appInstallerTitles = []
            }
            appInstallerDeployments = await optional("App Installer deployments (needs Read App Installers)") {
                try await client.fetchAppInstallerDeployments()
            } ?? []

            reanalyse()
            lastRefreshed = .now
        } catch {
            errorMessage = error.localizedDescription
        }
        progressMessage = ""
    }

    /// Re-runs the comparison against the cached data (used when filter options change).
    func reanalyse() {
        rows = PatchAnalyzer.analyse(
            installed: installed,
            configurations: configurations,
            patchPolicies: patchPolicies,
            availableTitles: availableTitles,
            appInstallerTitles: appInstallerTitles,
            appInstallerDeployments: appInstallerDeployments,
            options: options
        )
    }

    /// Runs a non-essential fetch, recording a warning and returning nil if it fails.
    private func optional<T>(_ label: String, _ fetch: () async throws -> [T]) async -> [T]? {
        do {
            return try await fetch()
        } catch {
            warnings.append("\(label): \(error.localizedDescription)")
            return nil
        }
    }

    private func recordTitlesScanned(count: Int) {
        titlesLastScanned = .now
        titlesLastScannedCount = count
        UserDefaults.standard.set(titlesLastScanned, forKey: "titlesLastScanned")
        UserDefaults.standard.set(count, forKey: "titlesLastScannedCount")
    }
}
