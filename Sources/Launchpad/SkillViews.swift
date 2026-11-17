#if os(macOS)
import SwiftUI
import LaunchpadCore

/// "Save as Skill": a bot writes up what happened in the chat (or one stretch of it) as a SKILL.md; you name it,
/// edit it and save it. Then "/name what you want" in any chat uses it.
struct TeachSkillSheet: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var text = ""
    @State private var share = true

    var body: some View {
        let teach = model.teach
        let audience = teach.flatMap { model.skillAudienceName(for: $0.chatId) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: "graduationcap.fill", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save as a skill")
                        .font(Theme.rounded(.title3, weight: .bold))
                    Text(teach?.messageId == nil
                         ? "A write-up of what happened in this chat. Name it, edit it, then save it."
                         : "A write-up of your request down to that reply. Name it, edit it, then save it.")
                        .foregroundStyle(Theme.secondary)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Text("Name").foregroundStyle(Theme.secondary)
                TextField("Name", text: $name, prompt: Text("e.g. release-notes"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .accessibilityLabel("Skill name")
                if let id = try? SkillCapture.skillId(name) {
                    Text("Use it with /\(id)")
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            switch teach?.phase {
            case .drafting:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Writing a draft…").foregroundStyle(Theme.secondary)
                }
                ScrollView {
                    Text(teach?.draft ?? "")
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                Spacer()
            case .ready:
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Space.s)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.line))
                    .accessibilityLabel("Skill draft")
            case nil:
                Spacer()
            }
            if let error = teach?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let audience {
                    Toggle("Give it to \(audience)", isOn: $share)
                        .toggleStyle(.checkbox)
                        .help("Off: the skill is saved to your library only. You can still use it anywhere with /name.")
                }
                Spacer()
                Button("Cancel") { model.cancelTeach() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Skill") { model.saveTaughtSkill(text, name: name, share: share && audience != nil) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle())
                    .disabled(teach?.phase != .ready
                              || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Space.xl)
        .frame(width: 680, height: 620)
        .sheetBackground()
        .onChange(of: model.teach?.phase) {
            guard model.teach?.phase == .ready else { return }
            text = model.teach?.draft ?? ""
            // A name you typed while the draft was being written wins over the bot's suggestion.
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = SkillFile.parse(text).name ?? ""
            }
        }
        .onChange(of: name) { model.teach?.error = nil }
    }
}

/// The skills that match the "/name" being typed, shown above the composer.
struct SkillCommandList: View {
    let skills: [Skill]
    let selection: Int
    let pick: (Skill) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(skills.enumerated()), id: \.element.id) { i, skill in
                        Button { pick(skill) } label: {
                            HStack(spacing: Theme.Space.s) {
                                Text("/\(skill.id)")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .fixedSize()
                                Text(skill.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Theme.Space.s)
                            .padding(.vertical, 6)
                            .background(
                                i == selection ? Theme.accentSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use the \(skill.id) skill. \(skill.description)")
                        .accessibilityAddTraits(i == selection ? .isSelected : [])
                        .id(i)
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: min(CGFloat(skills.count) * 32 + 12, 236))
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
        .frame(maxWidth: 560)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}
#endif
