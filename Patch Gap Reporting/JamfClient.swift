import Foundation

/// How the app signs in to Jamf Pro.
nonisolated enum JamfAuthMethod: String, CaseIterable, Identifiable, Sendable {
    case apiClient
    case userAccount

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apiClient: "API client"
        case .userAccount: "User account"
        }
    }
}

nonisolated struct JamfCredentials: Sendable {
    let serverURL: URL
    let method: JamfAuthMethod
    /// Client ID or username.
    let identifier: String
    /// Client secret or password.
    let secret: String
}

nonisolated enum JamfError: LocalizedError {
    case invalidServerURL
    case authenticationFailed(Int)
    case http(status: Int, path: String)
    case decoding(path: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The Jamf Pro URL isn't valid. Use the form https://yourorg.jamfcloud.com."
        case .authenticationFailed(let status):
            "Jamf Pro rejected the credentials (HTTP \(status))."
        case .http(let status, let path):
            switch status {
            case 401, 403:
                "Access denied to \(path) (HTTP \(status)). Check the API role privileges."
            default:
                "Jamf Pro returned HTTP \(status) for \(path)."
            }
        case .decoding(let path, let underlying):
            "Couldn't read the response from \(path): \(Self.describe(underlying))"
        }
    }

    /// Names the field that failed, which `DecodingError.localizedDescription` leaves out.
    private static func describe(_ error: Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing field \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) (at \(path(context)))"
        @unknown default:
            return error.localizedDescription
        }
    }
}

/// Talks to the Jamf Pro API and Classic API using a bearer token.
actor JamfClient {
    private let credentials: JamfCredentials
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var token: String?
    private var tokenExpiry = Date.distantPast

    init(credentials: JamfCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: - Public fetches

    /// Every application in computer inventory, one entry per computer per app.
    /// - Parameter progress: Called with (computers fetched, total computers) after each page.
    func fetchInventoryApplications(
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) async throws -> [(computerID: String, app: InventoryApplication)] {
        var output: [(String, InventoryApplication)] = []
        let computers: [InventoryComputer] = try await getAllPages(
            "/api/v1/computers-inventory",
            query: [URLQueryItem(name: "section", value: "APPLICATIONS")],
            pageSize: 200,
            progress: progress
        )
        for computer in computers {
            for app in computer.applications ?? [] {
                output.append((computer.id, app))
            }
        }
        return output
    }

    /// The titles configured under Settings > Computer Management > Patch Management.
    func fetchPatchTitleConfigurations() async throws -> [PatchTitleConfiguration] {
        try await get("/api/v2/patch-software-title-configurations")
    }

    /// Patch policies, used to tell actively patched titles from reporting-only ones.
    func fetchPatchPolicies() async throws -> [PatchPolicy] {
        try await getAllPages("/api/v2/patch-policies", pageSize: 200)
    }

    /// Every title offered by the Jamf patch source(s), including ones not yet added.
    func fetchPatchAvailableTitles() async throws -> [PatchAvailableTitle] {
        // The Classic API's JSON changes shape (e.g. a single item becomes an object, not an array),
        // so these two endpoints are read as XML, which is stable.
        // Internal sources are Jamf's own patch servers; fall back to ID 1 (Jamf) if the list fails.
        var sourceIDs = [1]
        if let data = try? await getData("/JSSResource/patchinternalsources", accept: "application/xml") {
            let ids = ClassicXMLRecords.parse(data, recordElement: "patch_internal_source").compactMap { $0["id"].flatMap(Int.init) }
            if !ids.isEmpty { sourceIDs = ids }
        }

        var titles: [PatchAvailableTitle] = []
        for id in sourceIDs {
            let path = "/JSSResource/patchavailabletitles/sourceid/\(id)"
            let data = try await getData(path, accept: "application/xml")
            titles += ClassicXMLRecords.parse(data, recordElement: "available_title").compactMap { record in
                guard let appName = record["app_name"], !appName.isEmpty else { return nil }
                return PatchAvailableTitle(
                    nameId: record["name_id"] ?? "",
                    appName: appName,
                    publisher: record["publisher"],
                    currentVersion: record["current_version"]
                )
            }
        }
        return titles
    }

    /// Every Jamf App Catalog title available as an App Installer.
    func fetchAppInstallerTitles() async throws -> [AppInstallerTitle] {
        try await getAllPages("/api/v1/app-installers/titles", pageSize: 200)
    }

    /// App Installer deployments already set up in this Jamf Pro instance.
    func fetchAppInstallerDeployments() async throws -> [AppInstallerDeployment] {
        try await getAllPages("/api/v1/app-installers/deployments", pageSize: 200)
    }

    // MARK: - Requests

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await getData(path, query: query)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw JamfError.decoding(path: path, underlying: error)
        }
    }

    private func getData(_ path: String, query: [URLQueryItem] = [], accept: String = "application/json") async throws -> Data {
        guard var components = URLComponents(url: credentials.serverURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw JamfError.invalidServerURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw JamfError.invalidServerURL }

        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JamfError.http(status: status, path: path) }
        return data
    }

    private func getAllPages<Item: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = [],
        pageSize: Int,
        progress: (@MainActor @Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [Item] {
        var items: [Item] = []
        var page = 0
        while true {
            let pageQuery = query + [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page-size", value: String(pageSize)),
                URLQueryItem(name: "sort", value: "id:asc"),
            ]
            let response: PagedResponse<Item> = try await get(path, query: pageQuery)
            items += response.results
            await progress?(items.count, response.totalCount)
            if response.results.isEmpty || items.count >= response.totalCount { break }
            page += 1
        }
        return items
    }

    // MARK: - Authentication

    /// Returns a cached token, or requests a new one when it is close to expiring.
    private func validToken() async throws -> String {
        if let token, tokenExpiry > .now { return token }

        var request: URLRequest
        switch credentials.method {
        case .apiClient:
            request = URLRequest(url: credentials.serverURL.appending(path: "/api/oauth/token"))
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let body = [
                "grant_type": "client_credentials",
                "client_id": credentials.identifier,
                "client_secret": credentials.secret,
            ]
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            request.httpBody = Data(body.utf8)
        case .userAccount:
            request = URLRequest(url: credentials.serverURL.appending(path: "/api/v1/auth/token"))
            let basic = Data("\(credentials.identifier):\(credentials.secret)".utf8).base64EncodedString()
            request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw JamfError.authenticationFailed(status) }

        let newToken: String
        let lifetime: TimeInterval
        switch credentials.method {
        case .apiClient:
            let decoded = try decoder.decode(OAuthTokenResponse.self, from: data)
            newToken = decoded.accessToken
            lifetime = TimeInterval(decoded.expiresIn)
        case .userAccount:
            newToken = try decoder.decode(UserTokenResponse.self, from: data).token
            lifetime = 20 * 60
        }
        // Renew a minute early so long inventory pulls never use an expired token.
        token = newToken
        tokenExpiry = Date.now.addingTimeInterval(max(lifetime - 60, 30))
        return newToken
    }

    /// Percent-encodes a value for an `application/x-www-form-urlencoded` body.
    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
