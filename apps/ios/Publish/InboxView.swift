import SwiftUI

struct InboxView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var client = PublisherClient()
    @State private var discovery = Discovery()
    @State private var settings = ProcessInfo.processInfo.arguments.contains("--publisher-settings")
    @State private var connectionID = UUID()
    @State private var editor: AppEditorItem?
    @State private var deletingApp: AppBuilds?
    @State private var deletingBuild: PublishedBuild?

    var body: some View {
        NavigationStack {
            List {
                ForEach(client.apps) { app in
                    Section {
                        if app.builds.isEmpty { Text("No builds").foregroundStyle(.secondary) }
                        ForEach(app.builds) { build in
                            BuildRow(build: build) { await client.install(build) }
                                .swipeActions { Button("Delete", role: .destructive) { deletingBuild = build } }
                                .contextMenu { Button("Delete build", role: .destructive) { deletingBuild = build } }
                        }
                    } header: {
                        HStack {
                            Text(app.name).font(.headline).foregroundStyle(.primary).textCase(nil)
                            Spacer()
                            Menu {
                                Button("Rename", systemImage: "pencil") { editor = AppEditorItem(bundleID: app.id, name: app.name) }
                                Button("Delete app", systemImage: "trash", role: .destructive) { deletingApp = app }
                            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                            .disabled(!client.connected)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if client.apps.isEmpty {
                    ContentUnavailableView {
                        Label(client.connected ? "No apps yet" : "Connect your Mac", systemImage: "shippingbox")
                    } description: {
                        Text(client.connected ? "Ready to receive." : "Open your publisher to get started.")
                    } actions: {
                        if !client.connected { Button("Connect") { settings = true }.buttonStyle(.bordered) }
                        else { Button("Add app") { editor = AppEditorItem(bundleID: "", name: "") }.buttonStyle(.bordered) }
                    }
                }
            }
            .navigationTitle("Publish")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Circle().fill(client.connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)).frame(width: 6, height: 6)
                        Text(client.connected ? "Connected" : client.connecting ? "Connecting" : "Offline")
                            .font(.caption).foregroundStyle(.secondary)
                    }.fixedSize().accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add app", systemImage: "plus") { editor = AppEditorItem(bundleID: "", name: "") }.disabled(!client.connected)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Publisher", systemImage: "server.rack") { settings = true }
                }
            }
            .refreshable { connectionID = UUID() }
            .sheet(isPresented: $settings) {
                PublisherSettings(client: client, discovery: discovery) {
                    settings = false
                    connectionID = UUID()
                }
            }
            .sheet(item: $editor) { item in
                AppEditor(item: item) { bundle, name in
                    let saved = await client.saveApp(bundleID: bundle, name: name)
                    let error = client.error
                    client.error = nil
                    return saved ? nil : error ?? "Couldn’t save this app."
                }
            }
            .confirmationDialog("Delete build?", isPresented: Binding(get: { deletingBuild != nil }, set: { if !$0 { deletingBuild = nil } }), presenting: deletingBuild) { build in
                Button("Delete build", role: .destructive) { Task { _ = await client.deleteBuild(build); deletingBuild = nil } }
            } message: { build in Text("Deletes version \(build.version), build \(build.build) from the publisher. Installed apps are unchanged.") }
            .confirmationDialog("Delete app and builds?", isPresented: Binding(get: { deletingApp != nil }, set: { if !$0 { deletingApp = nil } }), presenting: deletingApp) { app in
                Button("Delete app and builds", role: .destructive) { Task { _ = await client.deleteApp(app); deletingApp = nil } }
            } message: { app in Text("Deletes \(app.name) and its published builds. Installed apps and their data are unchanged.") }
            .alert("Publish", isPresented: Binding(get: { client.error != nil }, set: { if !$0 { client.error = nil } })) {
                Button("OK") { client.error = nil }
                Button("Publisher") { client.error = nil; settings = true }
            } message: { Text(client.error ?? "") }
            .task(id: "\(scenePhase)-\(connectionID)") {
                if scenePhase == .active {
                    discovery.start()
                    await client.run()
                } else {
                    discovery.stop()
                    await client.disconnect()
                }
            }
        }
    }
}

private struct BuildRow: View {
    let build: PublishedBuild
    let install: () async -> Void
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(build.version)  #\(build.build)").font(.body.weight(.medium)).monospacedDigit()
                HStack(spacing: 8) {
                    if let configuration = build.configuration { Text(configuration) }
                    Text(ByteCountFormatter.string(fromByteCount: build.sizeBytes, countStyle: .file))
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(build.expired ? "Expired" : "Install") { Task { await install() } }
                .buttonStyle(.bordered).disabled(build.expired)
        }.padding(.vertical, 6)
    }
}

private struct PublisherSettings: View {
    @Bindable var client: PublisherClient
    let discovery: Discovery
    let connect: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if !discovery.publishers.isEmpty {
                    Section("Nearby") {
                        ForEach(discovery.publishers) { publisher in
                            Button(publisher.name) {
                                client.address = publisher.url.absoluteString
                                connect()
                            }
                        }
                    }
                }
                Section("Publisher") {
                    if let issue = client.connectionIssue { Text(issue).foregroundStyle(.secondary) }
                    TextField("https://your-mac.tailnet.ts.net/ios-publish", text: $client.address)
                        .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("publisher-address")
                    Button("Connect", action: connect).disabled(URL(string: client.address).map { !PublisherClient.validURL($0) } ?? true)
                }
                if let id = client.receiverID {
                    Section("Device ID") { Text(id).font(.footnote.monospaced()).textSelection(.enabled) }
                }
            }
            .navigationTitle("Publisher").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct AppEditorItem: Identifiable {
    let id = UUID()
    let bundleID: String
    let name: String
}

private struct AppEditor: View {
    let item: AppEditorItem
    let save: (String, String) async -> String?
    @State private var name = ""
    @State private var bundleID = ""
    @State private var saving = false
    @State private var saveError: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                TextField("App name", text: $name).accessibilityIdentifier("app-name")
                TextField("Bundle ID", text: $bundleID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!item.bundleID.isEmpty).accessibilityIdentifier("app-bundle-id")
            }
            .navigationTitle(item.bundleID.isEmpty ? "Add app" : "Rename app")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            if let error = await save(bundleID, name) { saveError = error }
                            else { dismiss() }
                            saving = false
                        }
                    }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !bundleID.contains("."))
                }
            }
            .onAppear { name = item.name; bundleID = item.bundleID }
            .alert("Couldn’t save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
        }
    }
}
