#if os(macOS)
import SwiftUI
import LaunchpadCore

struct AvatarView: View {
    let bot: Bot?
    let size: CGFloat

    var body: some View {
        let colour = Color(hex: bot?.colour ?? "#B5A698")
        ZStack {
            Circle()
                .fill(colour.opacity(0.22))
            Circle()
                .strokeBorder(colour.opacity(0.55), lineWidth: max(1, size / 24))
            Text(bot?.emoji ?? "?")
                .font(.system(size: size * 0.52))
        }
        .frame(width: size, height: size)
        .accessibilityLabel(bot?.name ?? "Unknown bot")
    }
}

// MARK: - List

struct BotListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.bots.isEmpty {
                VStack(spacing: 10) {
                    Text("No bots yet.")
                        .font(Theme.rounded(.headline))
                    Text("Each bot is a folder in ~/Launchpad/bots. Make one here, or drop a folder in.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Bot") { model.showingNewBot = true }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedBotId) {
                    ForEach(model.bots) { bot in
                        HStack(spacing: 10) {
                            AvatarView(bot: bot, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bot.name)
                                    .font(Theme.rounded(.body, weight: .semibold))
                                Text(bot.role.isEmpty ? bot.engine.displayName : bot.role)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(bot.id)
                        .contextMenu {
                            Button("Message \(bot.name)") { model.openChat(with: bot) }
                            Button("Show in Finder") { SystemActions.reveal(model.paths.botDir(bot.id)) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Theme.canvas)
        .navigationTitle("Bots")
        .toolbar {
            ToolbarItem {
                Button {
                    model.showingNewBot = true
                } label: {
                    Label("New Bot", systemImage: "plus")
                }
                .help("Create a bot")
            }
        }
    }
}

// MARK: - Shared form

struct BotFormSections: View {
    @Binding var bot: Bot

    var body: some View {
        Section("Who they are") {
            TextField("Name", text: $bot.name, prompt: Text("e.g. Pixel"))
            TextField("Role", text: $bot.role, prompt: Text("e.g. Frontend engineer who loves clean UI"))
            LabeledContent("Avatar") {
                VStack(alignment: .trailing, spacing: 8) {
                    EmojiPicker(selection: $bot.emoji)
                    ColourPicker(selection: $bot.colour)
                }
            }
        }

        Section {
            Picker("Engine", selection: $bot.engine) {
                ForEach(BotEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)
            TextField("Model", text: Binding(
                get: { bot.model ?? "" },
                set: { bot.model = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            ), prompt: Text(bot.engine == .claude ? "Default (or opus, sonnet…)" : "Default (or gpt-5-codex…)"))
        } header: {
            Text("Engine")
        } footer: {
            Text("Runs on your \(bot.engine.planName) plan through \(bot.engine.displayName).")
        }

        Section {
            Picker("Permission", selection: $bot.permission) {
                ForEach(PermissionLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
        } header: {
            Text("What it can do")
        } footer: {
            Text(bot.permission.explanation)
        }
    }
}

struct EmojiPicker: View {
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 10), spacing: 4) {
                ForEach(BotPalette.emojis, id: \.self) { emoji in
                    Button {
                        selection = emoji
                    } label: {
                        Text(emoji)
                            .font(.system(size: 17))
                            .frame(width: 26, height: 26)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selection == emoji ? Theme.accent.opacity(0.25) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                Text("or type one")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { selection },
                    set: { if let first = $0.last { selection = String(first) } }
                ))
                .frame(width: 40)
                .multilineTextAlignment(.center)
            }
        }
    }
}

struct ColourPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(BotPalette.colours, id: \.self) { hex in
                Button {
                    selection = hex
                } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 20, height: 20)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(selection.uppercased() == hex.uppercased() ? 0.7 : 0), lineWidth: 2)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
    }
}

// MARK: - New bot

struct NewBotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var bot = Bot(id: "", name: "", emoji: BotPalette.emojis.randomElement() ?? "🤖",
                                 colour: BotPalette.colours.randomElement() ?? BotPalette.default)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                AvatarView(bot: bot, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.name.isEmpty ? "New bot" : bot.name)
                        .font(Theme.rounded(.title2, weight: .bold))
                    Text("A new teammate with its own folder, memory and workspace.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Form {
                BotFormSections(bot: $bot)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Bot") {
                    if let created = model.createBot(from: bot) {
                        dismiss()
                        model.openChat(with: created)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(bot.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 680)
    }
}

// MARK: - Memory

struct MemorySection: View {
    @Environment(AppModel.self) private var model
    let botId: String
    @State private var outline: [MemoryBook.OutlineTopic]? = []
    @State private var newFact = ""
    @State private var topic = MemoryBook.allTopics.first ?? "Notes"
    @State private var learns = true
    @State private var message: String?

    var body: some View {
        Section {
            Toggle("Learn from chats", isOn: Binding(get: { learns }, set: {
                learns = $0
                model.reviewer.setLearning($0, botId: botId)
            }))
            if let outline {
                ForEach(outline) { t in
                    if !t.entries.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.title ?? "Intro").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(t.entries) { e in
                                HStack(alignment: .top) {
                                    Text(e.text).fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    Button {
                                        show(model.memory.deleteEntry(at: e.position, expecting: e.text, botId: botId))
                                    } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                        .help("Forget this")
                                }
                            }
                        }
                    }
                }
                HStack {
                    TextField("Remember…", text: $newFact)
                    Picker("", selection: $topic) {
                        ForEach(MemoryBook.allTopics, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Button("Add") {
                        show(model.memory.addEntry(newFact, topic: topic, botId: botId))
                        newFact = ""
                    }
                    .disabled(newFact.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Label("MEMORY.md isn't plain text Launchpad can read, so it's left alone.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open MEMORY.md") { SystemActions.open(model.paths.memoryMD(botId)) }
                Button("Undo Last Change") {
                    let n = model.memory.undoLastChange(botId) ?? 0
                    message = n > 0 ? "Undone." : "Nothing to undo."
                    reload()
                }
                .disabled(!model.memory.canUndoLastChange(botId))
            }
        } header: {
            Text("Memory")
        } footer: {
            Text("What this bot remembers, in MEMORY.md. When a chat goes quiet, Launchpad files lasting facts here (never passwords or keys).")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        outline = model.memory.outline(botId)
        learns = model.reviewer.learns(botId)
    }

    private func show(_ result: MemoryEditResult) {
        switch result {
        case .secret: message = "That looks like a password or key, so it isn't saved."
        case .unreadable: message = "MEMORY.md couldn't be read, so nothing was changed."
        case .notFound: message = "That line changed in the meantime. Try again."
        default: message = nil
        }
        reload()
    }
}

// MARK: - Detail / edit

struct BotDetailView: View {
    @Environment(AppModel.self) private var model
    let botId: String

    @State private var draft: Bot?
    @State private var original: Bot?
    @State private var instructions = ""
    @State private var originalInstructions = ""
    @State private var confirmDelete = false

    private var isDirty: Bool { draft != original || instructions != originalInstructions }

    var body: some View {
        Group {
            if let binding = Binding($draft), let bot = draft {
                VStack(spacing: 0) {
                    header(bot)
                    Form {
                        BotFormSections(bot: binding)
                        Section {
                            TextEditor(text: $instructions)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 240)
                        } header: {
                            Text("Instructions")
                        } footer: {
                            Text("Saved to CLAUDE.md and AGENTS.md in the bot's folder, so both engines read the same thing.")
                        }
                        Section {
                            if model.skills.isEmpty {
                                Text("No skills yet. Add some on the Skills page.").foregroundStyle(.secondary)
                            }
                            ForEach(model.skills) { skill in
                                Toggle(isOn: Binding(
                                    get: { model.bot(botId)?.skills.contains(skill.id) ?? false },
                                    set: { _ in model.toggle(skill: skill.id, for: botId) }
                                )) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(skill.name)
                                        Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            let inherited = model.groups(containing: botId).flatMap { g in g.skills.map { (g, $0) } }
                            ForEach(inherited, id: \.1) { pair in
                                Label("\(pair.1) (from \(pair.0.displayName))", systemImage: "person.3")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Skills")
                        } footer: {
                            Text("Linked into the bot's folder (.claude/skills and .agents/skills) so Claude Code and Codex pick them up.")
                        }
                        Section {
                            if model.connectors.isEmpty {
                                Text("No connectors yet. Add MCP servers on the Connectors page.").foregroundStyle(.secondary)
                            }
                            ForEach(model.connectors) { c in
                                Toggle(c.name, isOn: Binding(
                                    get: { model.bot(botId)?.connectors.contains(c.id) ?? false },
                                    set: { _ in model.toggle(connector: c.id, for: botId) }
                                ))
                            }
                        } header: {
                            Text("Connectors")
                        } footer: {
                            Text("Only the connectors turned on here (or for its groups) are available to this bot.")
                        }
                        MemorySection(botId: botId)
                        Section {
                            Button("Move Bot to Trash…", role: .destructive) { confirmDelete = true }
                        }
                    }
                    .formStyle(.grouped)
                }
            } else {
                ContentUnavailableView("Bot not found", systemImage: "questionmark.circle")
            }
        }
        .background(Theme.canvas)
        .navigationTitle(draft?.name ?? "Bot")
        .toolbar {
            ToolbarItemGroup {
                if isDirty {
                    Button("Revert") { load() }
                }
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty)
            }
        }
        .onAppear(perform: load)
        .onChange(of: model.bots) {
            // Pick up edits made to the files by you or another agent.
            if !isDirty { load() }
        }
        .confirmationDialog("Move \(draft?.name ?? "this bot") to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteBot(botId) }
        } message: {
            Text("Its folder, notes and workspace go to the Trash, so you can still get them back.")
        }
    }

    private func header(_ bot: Bot) -> some View {
        HStack(spacing: 14) {
            AvatarView(bot: bot, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name.isEmpty ? "Unnamed" : bot.name)
                    .font(Theme.rounded(.title2, weight: .bold))
                Text("~/Launchpad/bots/\(botId)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                SystemActions.reveal(model.paths.botDir(botId))
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            Button {
                if let saved = model.bot(botId) { model.openChat(with: saved) }
            } label: {
                Label("Message", systemImage: "bubble.left.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
    }

    private func load() {
        guard let bot = model.bot(botId) else { return }
        draft = bot
        original = bot
        let text = model.botStore.instructions(for: botId)
        instructions = text
        originalInstructions = text
    }

    private func save() {
        guard var bot = draft else { return }
        bot.name = bot.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if bot.name.isEmpty { bot.name = original?.name ?? botId }
        model.saveBot(bot, instructions: instructions != originalInstructions ? instructions : nil)
        load()
    }
}
#endif
