import Foundation

// MARK: - Authentication

/// Response from `POST /api/oauth/token` (API client credentials).
nonisolated struct OAuthTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
    }
}

/// Response from `POST /api/v1/auth/token` (user account, basic auth).
nonisolated struct UserTokenResponse: Decodable, Sendable {
    let token: String
}

// MARK: - Jamf Pro API

/// Standard paged envelope used by most Jamf Pro API list endpoints.
nonisolated struct PagedResponse<Item: Decodable & Sendable>: Decodable, Sendable {
    let totalCount: Int
    let results: [Item]
}

/// A computer from `GET /api/v1/computers-inventory?section=APPLICATIONS`.
nonisolated struct InventoryComputer: Decodable, Sendable {
    let id: String
    let applications: [InventoryApplication]?
}

nonisolated struct InventoryApplication: Decodable, Sendable {
    let name: String
    let path: String?
    let version: String?
    let bundleId: String?
}

/// A configured Patch Management title from `GET /api/v2/patch-software-title-configurations`.
nonisolated struct PatchTitleConfiguration: Decodable, Sendable {
    let id: String
    let displayName: String?
    let softwareTitleName: String?
    let softwareTitleNameId: String?
    let softwareTitlePublisher: String?
    let patchSourceName: String?

    /// The catalogue title name, falling back to the admin-supplied display name.
    var titleName: String { softwareTitleName ?? displayName ?? "Unknown" }

    /// Jamf marks Combined Definitions in the publisher (e.g. "AgileBits (Combined Definition)"),
    /// and occasionally in the title name, so check both.
    var isCombinedDefinition: Bool {
        [softwareTitleName, softwareTitlePublisher, displayName].contains { $0?.localizedCaseInsensitiveContains("Combined Definition") == true }
    }
}

/// Jamf's own install counts for a configured title, from
/// `GET /api/v2/patch-software-title-configurations/{id}/patch-summary`.
nonisolated struct PatchSummary: Decodable, Sendable {
    let upToDate: Int?
    let outOfDate: Int?

    var computerCount: Int { (upToDate ?? 0) + (outOfDate ?? 0) }
}

/// A patch policy from `GET /api/v2/patch-policies`. Field names have varied between
/// Jamf Pro releases, so both spellings are accepted.
nonisolated struct PatchPolicy: Decodable, Sendable {
    let id: String
    let name: String?
    let enabled: Bool
    let softwareTitleConfigurationId: String?

    enum CodingKeys: String, CodingKey {
        case id, policyName, name, policyEnabled, enabled, softwareTitleConfigurationId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .policyName)
            ?? container.decodeIfPresent(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .policyEnabled)
            ?? container.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? false
        softwareTitleConfigurationId = try container.decodeIfPresent(String.self, forKey: .softwareTitleConfigurationId)
    }
}

/// A Jamf App Catalog App Installer title from `GET /api/v1/app-installers/titles`.
nonisolated struct AppInstallerTitle: Decodable, Sendable {
    let id: String
    let titleName: String
    let bundleId: String?
    let publisher: String?
    let version: String?
}

/// An App Installer deployment from `GET /api/v1/app-installers/deployments`.
nonisolated struct AppInstallerDeployment: Decodable, Sendable {
    let id: String
    let name: String?
    let appTitleId: String?
    let enabled: Bool?
}

// MARK: - Classic API

/// A title offered by a patch source, from `GET /JSSResource/patchavailabletitles/sourceid/{id}`.
nonisolated struct PatchAvailableTitle: Sendable {
    let nameId: String
    let appName: String
    let publisher: String?
    let currentVersion: String?

    /// Combined Definitions cover every major version of an app in a single title.
    /// Jamf marks them in the publisher (e.g. "AgileBits (Combined Definition)") or, for some titles, the name.
    var isCombinedDefinition: Bool {
        appName.localizedCaseInsensitiveContains("Combined Definition")
            || publisher?.localizedCaseInsensitiveContains("Combined Definition") == true
    }

    /// The title name with "(Combined Definition)" appended when Jamf only shows it in the publisher.
    var displayName: String {
        isCombinedDefinition && !appName.localizedCaseInsensitiveContains("Combined Definition")
            ? "\(appName) (Combined Definition)"
            : appName
    }
}

/// Reads flat records out of a Classic API XML response, e.g. every `<available_title>`
/// as a dictionary of its child elements' text (`["app_name": "1Password (Combined Definition)", …]`).
nonisolated final class ClassicXMLRecords: NSObject, XMLParserDelegate {
    private let recordElement: String
    private var records: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    private init(recordElement: String) {
        self.recordElement = recordElement
    }

    static func parse(_ data: Data, recordElement: String) -> [[String: String]] {
        let delegate = ClassicXMLRecords(recordElement: recordElement)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.records
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == recordElement { current = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == recordElement, let record = current {
            records.append(record)
            current = nil
        } else if current != nil {
            current?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }
}
