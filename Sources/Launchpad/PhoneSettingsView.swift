#if os(macOS)
import SwiftUI
import AppKit
import LaunchpadCore

/// Settings › Mobile: let the Launchpad iPhone app connect, the code to pair it, and the phones paired so far.
struct PhoneSettingsSection: View {
    @State private var link = PhoneLinkController.shared
    @State private var removing: PhoneDevice?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { link.enabled }, set: { link.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat from your iPhone")
                    Text("Your bots keep running on this Mac. The Launchpad app on your phone finds it on the same Wi-Fi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if link.enabled {
                LabeledContent("Status") {
                    if link.running {
                        Label("On, as “\(link.macName)”", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                    } else if let problem = link.problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if link.problem != nil {
                    Button("Try again") { link.start() }
                }

                if link.running {
                    LabeledContent("Pairing code") {
                        HStack(spacing: 10) {
                            Text(spaced(link.code))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .textSelection(.enabled)
                            Button("New code") { link.newCode() }
                                .help("The old code stops working.")
                        }
                    }
                    if !link.addresses.isEmpty {
                        LabeledContent("Address") {
                            Text(link.addresses.map { "\($0):\(PhoneLink.port)" }.joined(separator: "  ·  "))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                if link.devices.isEmpty {
                    Text("No phones paired yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(link.devices) { device in
                        HStack {
                            Image(systemName: "iphone")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                Text(seen(device)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove…", role: .destructive) { removing = device }
                        }
                    }
                }
            }
        } header: {
            Text("Mobile")
        } footer: {
            Text("On your iPhone, open Launchpad, pick this Mac and type the code. Each phone gets its own key, kept in your Keychain; remove a phone here and it can’t connect any more. Anyone on your network can see the link is on, but only paired phones can read or send.")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this phone")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let removing { link.revoke(removing) }
                removing = nil
            }
        } message: {
            Text("It stops working straight away. You can pair it again with a new code.")
        }
        .task {
            // Keeps "last seen" and the addresses fresh while Settings is open.
            while !Task.isCancelled {
                link.refresh()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    private func seen(_ d: PhoneDevice) -> String {
        guard let last = d.lastSeen else { return "Paired \(d.pairedAt.formatted(date: .abbreviated, time: .omitted))" }
        if Date().timeIntervalSince(last) < 90 { return "Connected now" }
        return "Last seen \(last.formatted(.relative(presentation: .named)))"
    }
}
#endif
