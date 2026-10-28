import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        TabView(selection: $settings.settingsTab) {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            ProvidersSettings().tabItem { Label("AI Providers", systemImage: "sparkle") }.tag("ai")
        }
        .frame(width: 680, height: 480)
    }
}

struct GeneralSettings: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Appearance:", selection: $settings.appearance) {
                Text("Auto").tag(Appearance.auto); Text("Light").tag(Appearance.light); Text("Dark").tag(Appearance.dark)
            }.pickerStyle(.segmented).fixedSize()
            Picker("Default view:", selection: $settings.defaultView) {
                Text("Tree").tag(ViewMode.tree); Text("Text").tag(ViewMode.text)
            }.pickerStyle(.segmented).fixedSize()
            Picker("Expand tree to:", selection: $settings.defaultDepth) {
                Text("1").tag(1); Text("2").tag(2); Text("3").tag(3); Text("All").tag(99)
            }.pickerStyle(.segmented).fixedSize()
            LabeledContent("Data font size:") {
                Stepper("\(settings.fontSize) pt", value: $settings.fontSize, in: AppSettings.fontSizes)
                    .help("⌘+ / ⌘-")
            }
            Picker("✦ Ask uses:", selection: $settings.askProvider) {
                ForEach(ProviderDef.all) { p in
                    Text(settings.providers[p.id]!.name + (settings.hasKey(p.id) ? "" : " (no key)")).tag(p.id)
                }
            }.fixedSize()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ProvidersSettings: View {
    @Environment(AppSettings.self) private var settings
    @State private var selected = "openai"

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(ProviderDef.all) { p in
                    let on = selected == p.id
                    Button { selected = p.id } label: {
                        HStack(spacing: 8) {
                            Circle().fill(dot(p.id, on)).frame(width: 7, height: 7)
                            Text(settings.providers[p.id]!.name).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if settings.askProvider == p.id {
                                Text("Ask").font(.system(size: 10.5, weight: .medium)).foregroundStyle(on ? .white.opacity(0.85) : T.text2)
                            }
                        }
                        .foregroundStyle(on ? .white : T.text)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(on ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8).frame(width: 200).background(T.drawer)
            Divider()
            ProviderDetail(id: selected).id(selected)
        }
    }

    private func dot(_ id: String, _ on: Bool) -> Color {
        if case .err? = settings.verify[id] { return T.err }
        if settings.hasKey(id) { return T.ok }
        return on ? .white.opacity(0.5) : T.text3
    }
}

struct ProviderDetail: View {
    @Environment(AppSettings.self) private var settings
    let id: String
    @State private var showKey = false

    var body: some View {
        let def = ProviderDef.get(id)
        let cfg = Binding(get: { settings.providers[id]! }, set: { settings.providers[id] = $0; settings.verify[id] = nil })
        let key = Binding(get: { settings.key(id) }, set: { settings.setKey(id, $0) })
        VStack(alignment: .leading, spacing: 14) {
            field("Name") { TextField("", text: cfg.name) }
            field("API Key") {
                HStack {
                    Group {
                        if showKey { TextField(def.prefix + "…", text: key) } else { SecureField(def.prefix + "…", text: key) }
                    }.font(T.mono())
                    Button(showKey ? "Hide" : "Show") { showKey.toggle() }.frame(width: 56)
                }
                (Text("Stored in your macOS Keychain. Get a key at ") + Text(.init("[\(def.keyURL.replacingOccurrences(of: "https://", with: ""))](\(def.keyURL))")))
                    .font(.system(size: 11.5)).foregroundStyle(T.text2)
            }
            HStack(alignment: .top, spacing: 10) {
                field("Host") { TextField("", text: cfg.host) }
                field("Sub Path") { TextField("", text: cfg.path) }.frame(width: 110)
            }
            field("Default Model") {
                Picker("", selection: cfg.model) {
                    ForEach(def.models, id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            Toggle("Use for ✦ Ask", isOn: Binding(get: { settings.askProvider == id }, set: { if $0 { settings.askProvider = id } }))
            Spacer()
            Divider()
            HStack {
                Text(statusText.0).font(.system(size: 12)).foregroundStyle(statusText.1).lineLimit(2)
                Spacer()
                Button("Reset") { settings.reset(id) }
                Button("Verify Key") { settings.verifyKey(id) }.buttonStyle(.borderedProminent)
            }.padding(.top, -8)
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 13))
        .padding(.vertical, 22).padding(.horizontal, 32)
        .frame(maxWidth: 464, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: (String, Color) {
        switch settings.verify[id] {
        case .loading(let m)?: (m, T.text2)
        case .ok(let m)?: (m, T.ok)
        case .err(let m)?: (m, T.err)
        case nil: (settings.hasKey(id) ? "Key saved — not yet verified." : "No key saved.", T.text2)
        }
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label); c() }
    }
}
