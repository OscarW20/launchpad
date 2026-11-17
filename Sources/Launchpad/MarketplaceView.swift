#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// Teams, roles, skills and apps you can add in one click.
struct MarketplaceView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case teams = "Teams", roles = "Roles", skills = "Skills", apps = "Apps"
        var id: String { rawValue }
    }

    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .teams
    @State private var search = ""
    @State private var installing: ConnectorPreset?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Spacer()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch tab {
                    case .teams: teams
                    case .roles: roles
                    case .skills: skills
                    case .apps: apps
                    }
                }
                .padding(24)
                .frame(maxWidth: 1080)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Marketplace")
        .sheet(item: $installing) { preset in
            InstallAppSheet(preset: preset)
        }
    }

    private func matches(_ parts: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || parts.joined(separator: " ").lowercased().contains(q)
    }

    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 14)]

    // MARK: Teams

    @ViewBuilder private var teams: some View {
        ForEach(TeamPacks.all.filter { matches($0.name, $0.tagline) }) { pack in
            let hired = model.group(pack.groupId) != nil
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(pack.emoji) \(pack.name)")
                        .font(Theme.rounded(.title2, weight: .bold))
                    Text(pack.tagline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: -8) {
                        ForEach(pack.templates) { t in
                            AvatarView(bot: t.bot, size: 32)
                                .background(Circle().fill(Theme.surface))
                                .help(t.name)
                        }
                    }
                    Text("#\(pack.groupId) · lead: \(HireCatalog.template(pack.lead)?.name ?? pack.lead)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.hireTeam(pack)
                } label: {
                    Label(hired ? "Open #\(pack.groupId)" : "Add team", systemImage: hired ? "bubble.left.and.bubble.right.fill" : "person.3.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(20)
            .background(
                LinearGradient(colors: [Theme.accent.opacity(0.14), Theme.userBubble.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
        }
    }

    // MARK: Roles

    @ViewBuilder private var roles: some View {
        ForEach(HireCatalog.categories, id: \.self) { category in
            let items = HireCatalog.roles.filter { $0.category == category && matches($0.name, $0.role, $0.blurb) }
            if !items.isEmpty {
                Text(category).font(Theme.rounded(.title3, weight: .bold))
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { TemplateCard(template: $0) }
                }
            }
        }
    }

    // MARK: Skills

    @ViewBuilder private var skills: some View {
        ForEach(SkillCatalog.categories, id: \.self) { category in
            let items = SkillCatalog.all.filter { $0.category == category && matches($0.name, $0.blurb) }
            if !items.isEmpty {
                Text(category).font(Theme.rounded(.title3, weight: .bold))
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { skill in
                        let installed = model.skill(skill.id) != nil
                        CatalogCard(symbol: skill.symbol, logo: nil, tint: nil, title: skill.name, subtitle: skill.category, blurb: skill.blurb) {
                            if installed {
                                Label("In your library", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(Theme.success)
                                Spacer()
                                Button("Open") {
                                    model.selectedSkillId = skill.id
                                    model.section = .skills
                                }
                                .controlSize(.small)
                            } else {
                                Spacer()
                                Button("Add skill") { model.installSkill(skill) }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Apps

    @ViewBuilder private var apps: some View {
        ForEach(ConnectorCatalog.categories, id: \.self) { category in
            let items = ConnectorCatalog.all.filter { $0.category == category && matches($0.name, $0.blurb) }
            if !items.isEmpty {
                Text(category).font(Theme.rounded(.title3, weight: .bold))
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(items) { preset in
                        let installed = model.connectors.contains { $0.id == preset.id }
                        CatalogCard(symbol: preset.symbol, logo: preset.logo, tint: preset.tint, title: preset.name, subtitle: preset.category, blurb: preset.blurb) {
                            if installed {
                                Label("Added", systemImage: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(Theme.success)
                                Spacer()
                                Button("Settings") {
                                    model.selectedConnectorId = preset.id
                                    model.section = .connectors
                                }
                                .controlSize(.small)
                            } else {
                                Spacer()
                                Button("Add app") { installing = preset }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A logo from the bundled Logos folder, or an SF Symbol on a tint.
struct AppLogo: View {
    let logo: String?
    let symbol: String
    let tint: String?
    let size: CGFloat

    var body: some View {
        if let image = Self.load(logo) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.7, height: size * 0.7)
                .frame(width: size, height: size)
                .background(Color.white, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).strokeBorder(Theme.border))
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(tint.map { Color(hex: $0) } ?? Theme.accent, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        }
    }

    static func load(_ file: String?) -> NSImage? {
        guard let file else { return nil }
        let name = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        guard let url = AppResources.url(name, ext, in: "Logos") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct CatalogCard<Actions: View>: View {
    let symbol: String
    let logo: String?
    let tint: String?
    let title: String
    let subtitle: String
    let blurb: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppLogo(logo: logo, symbol: symbol, tint: tint, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.rounded(.headline, weight: .bold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(blurb)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack { actions() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
    }
}

struct InstallAppSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let preset: ConnectorPreset
    @State private var settings: [String: String] = [:]
    @State private var secrets: [String: String] = [:]
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AppLogo(logo: preset.logo, symbol: preset.symbol, tint: preset.tint, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \(preset.name)").font(Theme.rounded(.title2, weight: .bold))
                    Text(preset.blurb).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            Form {
                if !preset.settings.isEmpty {
                    Section("Settings") {
                        ForEach(preset.settings, id: \.key) { f in
                            TextField(f.label, text: Binding(get: { settings[f.key] ?? "" }, set: { settings[f.key] = $0 }), prompt: Text(f.help))
                        }
                    }
                }
                let secretFields = preset.secrets + (preset.token.map { [$0] } ?? [])
                if !secretFields.isEmpty {
                    Section {
                        ForEach(secretFields, id: \.key) { f in
                            SecureField(f.label, text: Binding(get: { secrets[f.key] ?? "" }, set: { secrets[f.key] = $0 }), prompt: Text(f.help))
                        }
                    } header: {
                        Text("Keys")
                    } footer: {
                        Text("Saved in your Keychain. You can add them later on the Connectors page.")
                    }
                }
                Section {
                    if let needs = preset.needs {
                        Label("Runs `\(needs)` on your Mac.", systemImage: "terminal")
                    }
                    if preset.signsIn {
                        Label("Sign in after adding it: Connectors → \(preset.name) → Sign in.", systemImage: "person.badge.key")
                    }
                    if let url = URL(string: preset.docsURL) {
                        Link("Docs", destination: url)
                    }
                }
                if let error {
                    Text(error).foregroundStyle(Theme.failure)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let e = model.installApp(preset, settings: settings, secrets: secrets) {
                        error = e
                    } else {
                        dismiss()
                        model.selectedConnectorId = preset.id
                        model.section = .connectors
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
    }
}
#endif
