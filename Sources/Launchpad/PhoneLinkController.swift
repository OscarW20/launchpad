#if os(macOS)
import AppKit
import Foundation
import Observation
import SystemConfiguration
import LaunchpadCore

/// Runs the phone link for the app: the server on port 8790, its Bonjour advert, the pairing code and the list of
/// paired phones shown in Settings › Mobile. Off until you switch it on.
@MainActor
@Observable
final class PhoneLinkController {
    static let shared = PhoneLinkController()
    static let enabledKey = "phone.enabled"

    /// The switch in Settings › Mobile.
    private(set) var enabled = UserDefaults.standard.bool(forKey: PhoneLinkController.enabledKey)
    private(set) var running = false
    /// Why it isn't running, in plain English.
    private(set) var problem: String?
    private(set) var code = ""
    private(set) var devices: [PhoneDevice] = []
    /// Addresses a phone can type in by hand.
    private(set) var addresses: [String] = []
    let macName = PhoneLinkController.computerName()

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var bridge: AppPhoneBridge?
    @ObservationIgnored private var server: PhoneLinkServer?
    @ObservationIgnored private var service: NetService?

    private init() {}

    /// Called once from AppModel.init.
    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        let bridge = AppPhoneBridge(model: model)
        let store = PhoneDeviceStore(file: model.paths.launchpadData.appendingPathComponent("phones.json"), secrets: model.secrets)
        let server = PhoneLinkServer(macName: macName, bridge: bridge, devices: store)
        server.onChange = { Task { @MainActor in PhoneLinkController.shared.refresh() } }
        self.bridge = bridge
        self.server = server
        refresh()
        if enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            // Replies from before the first phone was paired don't count as unread.
            if UserDefaults.standard.object(forKey: AppModel.phoneReadBaselineKey) == nil {
                UserDefaults.standard.set(Date(), forKey: AppModel.phoneReadBaselineKey)
            }
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard let server else { return }
        do {
            try server.start(port: PhoneLink.port)
            running = true
            problem = nil
            publish()
        } catch {
            running = false
            problem = "Couldn’t open port \(PhoneLink.port): \(error.localizedDescription). Is another copy of Launchpad open?"
        }
        refresh()
    }

    func stop() {
        service?.stop()
        service = nil
        server?.stop()
        running = false
        problem = nil
    }

    func newCode() { server?.newPairingCode() }

    func revoke(_ device: PhoneDevice) {
        server?.devices.revoke(device.id)
        refresh()
    }

    func refresh() {
        code = server?.pairingCode ?? ""
        devices = server?.devices.devices.sorted { $0.pairedAt < $1.pairedAt } ?? []
        addresses = Self.lanAddresses()
        if running, server?.isRunning == false {
            running = false
            problem = "The phone link stopped. Switch it off and on again."
        }
    }

    // MARK: Bonjour

    private func publish() {
        service?.stop()
        let s = NetService(domain: "local.", type: PhoneLink.serviceType + ".", name: macName, port: Int32(PhoneLink.port))
        let txt: [String: Data] = [
            "host": Data(Self.bonjourHost().utf8),
            "port": Data(String(PhoneLink.port).utf8),
            "v": Data(String(PhoneLink.version).utf8),
        ]
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.publish()
        service = s
    }

    /// "Studio.local": the name other devices on the network find this Mac by.
    static func bonjourHost() -> String {
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { return local + ".local" }
        return ProcessInfo.processInfo.hostName
    }

    /// The Mac's name as set in System Settings › General › Sharing.
    static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        return "Mac"
    }

    /// IPv4 addresses on this Mac's networks (Wi-Fi and Ethernet first, then Tailscale's 100.x).
    static func lanAddresses() -> [String] {
        var out: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (Int32(a.ifa_flags) & IFF_LOOPBACK) == 0, (Int32(a.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254"), !out.contains(ip) { out.append(ip) }
        }
        return out.sorted { a, b in a.hasPrefix("100.") == b.hasPrefix("100.") ? a < b : !a.hasPrefix("100.") }
    }
}
#endif
