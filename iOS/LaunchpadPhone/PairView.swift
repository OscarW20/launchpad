import SwiftUI

/// First run: find the Mac on this Wi-Fi and type the code from Settings › Mobile.
struct PairView: View {
    @Environment(MacLink.self) private var link
    @State private var picked: FoundMac?
    @State private var manual = ""
    @State private var showManual = false
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "paperplane.circle.fill").resizable().scaledToFit().frame(width: 84, height: 84)
                        .foregroundStyle(Theme.accent)
                    Text("Your team, in your pocket").font(.display(30, .bold)).foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text("Your bots keep working on your Mac. Chat with them from here.")
                        .font(.system(size: 16)).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
                }
                .padding(.top, 36)

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Pick your Mac")
                    if link.found.isEmpty && !showManual {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Launchpad on this Wi-Fi…").font(.system(size: 15)).foregroundStyle(Theme.subtle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bubbleIn))
                    }
                    ForEach(link.found) { mac in
                        Button { picked = mac; showManual = false; codeFocused = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "laptopcomputer").font(.system(size: 20)).foregroundStyle(Theme.accent)
                                    .frame(width: 40, height: 40).background(Circle().fill(Theme.soft))
                                Text(mac.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: picked == mac ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 22)).foregroundStyle(picked == mac ? Theme.accent : Theme.line)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bubbleIn))
                        }
                        .buttonStyle(.plain)
                    }
                    if showManual {
                        TextField("Mac address, like 192.168.1.20", text: $manual)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 17)).padding(16)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bubbleIn))
                    }
                    Button(showManual ? "Search the Wi-Fi instead" : "Type the address instead") {
                        showManual.toggle(); picked = nil
                    }
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent).padding(.leading, 4)
                }

                VStack(alignment: .leading, spacing: 10) {
                    step(2, "Type the code from your Mac")
                    Text("On your Mac: Launchpad › Settings › Mobile. Switch it on to see the code.").font(.system(size: 14)).foregroundStyle(Theme.subtle)
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad).textContentType(.oneTimeCode).focused($codeFocused)
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        .multilineTextAlignment(.center).padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bubbleIn))
                        .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
                }

                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(.red).multilineTextAlignment(.center)
                }

                Button {
                    Task { await connect() }
                } label: {
                    if busy { ProgressView().tint(.white) } else { Text("Connect") }
                }
                .buttonStyle(PillButton())
                .disabled(busy || code.count != 6 || target == nil)
                .opacity(code.count == 6 && target != nil ? 1 : 0.5)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.canvas.ignoresSafeArea())
        .onAppear { link.browse() }
        .onDisappear { link.stopBrowsing() }
        .onChange(of: link.found) { _, macs in if picked == nil, macs.count == 1 { picked = macs[0] } }
    }

    private var target: URL? { showManual ? MacLink.url(from: manual) : picked?.url }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.accent))
            Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
        }
    }

    private func connect() async {
        guard let target else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await link.pair(with: target, code: code) }
        catch { self.error = (error as? LocalizedError)?.errorDescription ?? "Couldn’t reach your Mac. Is Launchpad open, with Mobile switched on?" }
    }
}
