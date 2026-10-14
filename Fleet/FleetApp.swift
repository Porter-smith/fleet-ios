import SwiftUI
import FleetKit

@main
struct FleetApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    /// Dark by default, like the web chat.
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue

    var body: some View {
        Group {
            if let client = model.client {
                RunsListView(client: client)
                    .id(model.pairing)
            } else {
                PairingView()
            }
        }
        .preferredColorScheme((Appearance(rawValue: appearance) ?? .dark).scheme)
        .task(id: model.pairing) { await model.loadActor() }
    }
}

struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://fleet.example.ts.net", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pair.url")
                } header: {
                    Text("Server")
                } footer: {
                    Text("The Fleet server's address, over Tailscale or your LAN.")
                }
                Section {
                    SecureField("Fleet token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("pair.token")
                } header: {
                    Text("Token")
                } footer: {
                    Text("Make a token with the scopes runs:read, runs:control and runs:spawn. It's kept in this device's Keychain.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        Task { await pair() }
                    } label: {
                        HStack {
                            Text("Pair")
                            if busy {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(busy || url.isEmpty || token.isEmpty)
                    .accessibilityIdentifier("pair.submit")
                }
                Section {
                    Button("Try the demo") { model.startDemo() }
                        .accessibilityIdentifier("pair.demo")
                } footer: {
                    Text("Sample runs from a pretend server, to look around without one.")
                }
            }
            .navigationTitle("Pair with Fleet")
            .onAppear { if url.isEmpty { url = model.serverURL } }
        }
    }

    private func pair() async {
        busy = true
        error = nil
        do {
            try await model.pair(url: url, token: token)
            token = ""
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = Appearance.dark.rawValue

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                }
                Section("Server") {
                    LabeledContent("URL", value: model.serverURL)
                }
                if let actor = model.actor {
                    Section {
                        LabeledContent("Token", value: actor.name ?? actor.id ?? actor.kind)
                        ForEach(FleetKit.Actor.neededScopes, id: \.self) { scope in
                            let ok = actor.has(scope)
                            Label(scope, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(ok ? Color.green : Color.red)
                        }
                    } header: {
                        Text("Access")
                    } footer: {
                        if actor.missingScopes.isEmpty {
                            Text(actor.isAdmin ? "An admin token can do everything." : "This token can read, steer and start runs.")
                        } else {
                            Text("Missing \(actor.missingScopes.joined(separator: ", ")). Those actions will be refused; make a token with all three scopes.")
                        }
                    }
                }
                Section {
                    Button("Unpair", role: .destructive) {
                        model.unpair()
                        dismiss()
                    }
                } footer: {
                    Text("Removes the token from this device.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
