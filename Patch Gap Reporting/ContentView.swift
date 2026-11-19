import SwiftUI
import UniformTypeIdentifiers

/// Which rows the table shows.
enum RowFilter: String, CaseIterable, Identifiable {
    case unpatched = "Not patched"
    case reportingOnly = "Reporting only"
    case needsCombined = "Not Combined"
    case patched = "Patched"
    case all = "All"

    var id: String { rawValue }

    func includes(_ row: AppPatchRow) -> Bool {
        switch self {
        case .unpatched: row.status.hasNoTitle
        case .reportingOnly: row.status == .reportingOnly
        case .needsCombined: row.definition.needsCombined
        case .patched: row.status.isPatched
        case .all: true
        }
    }
}

struct ContentView: View {
    @State private var model = PatchGapModel()
    @State private var filter: RowFilter = .unpatched
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\AppPatchRow.computerCount, order: .reverse)]
    @State private var selection = Set<AppPatchRow.ID>()
    @State private var showingSettings = false
    @State private var showingExporter = false

    private var visibleRows: [AppPatchRow] {
        model.rows
            .filter { filter.includes($0) }
            .filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) || $0.bundleIDText.localizedCaseInsensitiveContains(searchText) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                MessageBanner(text: error, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            ForEach(model.warnings, id: \.self) { warning in
                MessageBanner(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }

            if model.rows.isEmpty && !model.isLoading {
                emptyState
            } else {
                table
            }

            Divider()
            footer
        }
        .frame(minWidth: 900, minHeight: 500)
        .navigationTitle("Patch Gap")
        .searchable(text: $searchText, prompt: "Search apps or bundle IDs")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(model: model)
        }
        .fileExporter(
            isPresented: $showingExporter,
            item: CSVExport(text: PatchAnalyzer.csv(for: visibleRows)),
            contentTypes: [.commaSeparatedText],
            defaultFilename: "Patch Gap \(filter.rawValue).csv"
        ) { _ in }
        .onChange(of: model.options.hideAppleApps) { model.reanalyse() }
        .onChange(of: model.options.applicationsFolderOnly) { model.reanalyse() }
        .task {
            if model.isConfigured {
                await model.refresh()
            } else {
                showingSettings = true
            }
        }
    }

    private var table: some View {
        Table(visibleRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("App", value: \.name) { row in
                VStack(alignment: .leading) {
                    Text(row.name)
                    if !row.bundleIDs.isEmpty {
                        Text(row.bundleIDText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 180, ideal: 240)
            TableColumn("Status", value: \.statusText) { row in
                StatusLabel(status: row.status)
            }
            .width(min: 160, ideal: 200)
            TableColumn("Definition", value: \.definitionText) { row in
                DefinitionLabel(definition: row.definition)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Computers", value: \.computerCount) { row in
                Text(row.computerCount, format: .number).monospacedDigit()
            }
            .width(min: 70, ideal: 80)
            TableColumn("Versions", value: \.versionText)
                .width(min: 80, ideal: 120)
            TableColumn("In Jamf as", value: \.jamfTitle)
                .width(min: 120, ideal: 180)
            TableColumn("Recommended patch title", value: \.recommendedPatchTitle)
                .width(min: 160, ideal: 230)
            TableColumn("App Installer available", value: \.appInstallerTitle)
                .width(min: 140, ideal: 180)
        }
        .overlay {
            if model.isLoading && model.rows.isEmpty {
                ProgressView(model.progressMessage)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isConfigured {
            ContentUnavailableView {
                Label("No Data Yet", systemImage: "shippingbox")
            } description: {
                Text("Refresh to compare installed apps with your Patch Management titles.")
            } actions: {
                Button("Refresh") { Task { await model.refresh() } }
            }
        } else {
            ContentUnavailableView {
                Label("Connect to Jamf Pro", systemImage: "server.rack")
            } description: {
                Text("Add your Jamf Pro URL and API client to get started.")
            } actions: {
                Button("Connection Settings…") { showingSettings = true }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text(model.progressMessage)
            } else {
                let unpatched = model.rows.filter(\.status.hasNoTitle).count
                let reporting = model.rows.filter { $0.status == .reportingOnly }.count
                let combined = model.rows.filter { $0.definition == .combined }.count
                let notCombined = model.rows.filter(\.definition.needsCombined).count
                Text("\(model.rows.count) apps · \(unpatched) not patched · \(reporting) reporting only · \(combined) using Combined · \(notCombined) could switch to Combined")
                if let date = model.lastRefreshed {
                    Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                }
            }
            Spacer()
            titlesScannedNote
            Text("v\(Bundle.main.appVersion)")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    /// When the Jamf App Catalog App Installer title list was last scanned, linking to Jamf's published list.
    private var titlesScannedNote: some View {
        HStack(spacing: 4) {
            if let date = model.titlesLastScanned {
                Text("App Installer titles last scanned \(date.formatted(date: .abbreviated, time: .shortened)) (\(model.titlesLastScannedCount) titles)")
            } else {
                Text("App Installer titles not scanned yet")
            }
            if let url = URL(string: "https://learn.jamf.com/r/en-US/jamf-app-catalog/App_Installers_Software_Titles") {
                Link("View list", destination: url)
            }
        }
        .help("The Jamf App Catalog App Installer titles are read from Jamf Pro on each refresh. This is the same list Jamf publishes online.")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Show", selection: $filter) {
                ForEach(RowFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu("Filters", systemImage: "line.3.horizontal.decrease") {
                Toggle("Hide Apple apps", isOn: $model.options.hideAppleApps)
                Toggle("Only apps in /Applications", isOn: $model.options.applicationsFolderOnly)
            }
        }
        ToolbarItem {
            Button("Export CSV", systemImage: "square.and.arrow.up") { showingExporter = true }
                .disabled(visibleRows.isEmpty)
        }
        ToolbarItem {
            Button("Connection Settings", systemImage: "gearshape") { showingSettings = true }
        }
        ToolbarItem {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .disabled(model.isLoading || !model.isConfigured)
                .keyboardShortcut("r")
        }
    }
}

// MARK: - Supporting views

private struct StatusLabel: View {
    let status: PatchStatus

    var body: some View {
        switch status {
        case .patched:
            Label(status.rawValue, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .reportingOnly:
            Label(status.rawValue, systemImage: "eye.circle.fill").foregroundStyle(.orange)
        case .notPatchedAvailable:
            Label(status.rawValue, systemImage: "plus.circle.fill").foregroundStyle(.blue)
        case .notPatchedNoTitle:
            Label(status.rawValue, systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

private struct DefinitionLabel: View {
    let definition: DefinitionKind

    var body: some View {
        switch definition {
        case .combined:
            Label(definition.rawValue, systemImage: "square.stack.3d.up.fill").foregroundStyle(.green)
        case .versionSpecificCombinedAvailable:
            Label(definition.rawValue, systemImage: "arrow.triangle.merge").foregroundStyle(.orange)
        case .combinedAvailable:
            Label(definition.rawValue, systemImage: "square.stack.3d.up").foregroundStyle(.blue)
        case .standard, .standardAvailable, .appInstaller:
            Text(definition.rawValue).foregroundStyle(.secondary)
        case .none:
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

private struct MessageBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(tint.opacity(0.15))
            .textSelection(.enabled)
    }
}

private struct SettingsSheet: View {
    @Bindable var model: PatchGapModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Jamf Pro Connection").font(.title2.bold())
            Form {
                TextField("Jamf Pro URL", text: $model.serverURL, prompt: Text("https://yourorg.jamfcloud.com"))
                Picker("Sign in with", selection: $model.authMethod) {
                    ForEach(JamfAuthMethod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField(model.authMethod == .apiClient ? "Client ID" : "Username", text: $model.identifier)
                SecureField(model.authMethod == .apiClient ? "Client secret" : "Password", text: $model.secret)
            }
            Text("""
                The API role needs: Read Computers, Read Patch Management Software Titles, \
                Read Patch Policies, Read Patch Internal Sources and Read App Installers. The secret is stored in your keychain.
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save and Refresh") {
                    model.saveSettings()
                    dismiss()
                    Task { await model.refresh() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.isConfigured)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Exports the visible rows as a CSV file.
private struct CSVExport: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.text.utf8) }
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    ContentView()
}
