import SwiftUI
import UIKit
import Combine

@MainActor
final class HostModel: ObservableObject {
    @Published var consoleIP = ""
    @Published var consolePort = "8000"
    @Published var receivePort = "9000"
    @Published var httpPort = "8765"
    @Published var running = false
    @Published var requested = false
    @Published var status = "Enter your console settings, then start the bridge."
    @Published var inputs = 0
    @Published var mixes = 0
    @Published var addresses: [String] = []
    private let host = BridgeHost()
    init() {
        if let data = UserDefaults.standard.data(forKey: "bridge.settings"), let config = try? JSONDecoder().decode(BridgeConfig.self, from: data) {
            consoleIP = config.consoleIP; consolePort = String(config.consolePort)
            receivePort = String(config.receivePort); httpPort = String(config.httpPort)
        }
        host.onStatus = { [weak self] running, message, inputs, mixes in
            Task { @MainActor in
                guard let self = self else { return }
                self.running = running; self.status = message; self.inputs = inputs; self.mixes = mixes
                self.addresses = BridgeHost.localAddresses()
                if !running && !message.hasPrefix("Starting") { self.requested = false; UIApplication.shared.isIdleTimerDisabled = false }
            }
        }
        addresses = BridgeHost.localAddresses()
    }
    func start() {
        guard let out = UInt16(consolePort), let incoming = UInt16(receivePort), let http = UInt16(httpPort) else {
            status = "Ports must be whole numbers from 1024 to 65535."; return
        }
        let config = BridgeConfig(consoleIP: consoleIP.trimmingCharacters(in: .whitespacesAndNewlines), consolePort: out, receivePort: incoming, httpPort: http)
        do {
            try BridgeHost.validate(config)
            UserDefaults.standard.set(try JSONEncoder().encode(config), forKey: "bridge.settings")
            requested = true; status = "Starting bridge…"; UIApplication.shared.isIdleTimerDisabled = true
            host.start(config)
        } catch { status = (error as? BridgeFailure)?.message ?? error.localizedDescription }
    }
    func stop(background: Bool = false) {
        requested = false; running = false; UIApplication.shared.isIdleTimerDisabled = false
        host.stop(background ? "Stopped because the app entered the background. Return here and tap Start bridge." : "Bridge stopped. All mix reservations released.")
    }
}

@main
@MainActor
struct QuantumAuxBridgeApp: App {
    @StateObject private var model = HostModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Form {
                    Section {
                        Label(model.running ? "Bridge running" : "Bridge stopped", systemImage: model.running ? "antenna.radiowaves.left.and.right" : "pause.circle")
                            .font(.headline).foregroundStyle(model.running ? Color.green : Color.secondary)
                        Text(model.status).font(.callout)
                        if model.running { Text("\(model.inputs) inputs discovered · \(model.mixes) mixes reserved").font(.caption) }
                    }
                    Section("Console connection") {
                        TextField("Console IPv4 address", text: $model.consoleIP).keyboardType(.decimalPad)
                        port("Console receive UDP", $model.consolePort)
                        port("This device receive UDP", $model.receivePort)
                        port("Musician web port", $model.httpPort)
                    }.disabled(model.requested || model.running)
                    Section {
                        if model.requested || model.running {
                            Button("Stop bridge", role: .destructive) { model.stop() }
                        } else {
                            Button("Start bridge") { model.start() }.fontWeight(.semibold)
                        }
                    }
                    Section("Musician browser addresses") {
                        if model.addresses.isEmpty { Text("Connect this device to the console’s Wi-Fi network or Ethernet.") }
                        ForEach(model.addresses, id: \.self) { address in
                            let url = "http://\(address):\(model.httpPort)"
                            VStack(alignment: .leading, spacing: 8) {
                                Text(url).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                Button("Copy address") { UIPasteboard.general.string = url }.disabled(!model.running)
                            }
                        }
                        Text("Musicians open an address above on the same network and choose a free aux. One browser session can reserve each aux.").font(.caption)
                    }
                    Section("Console setup") {
                        Text("Enable the console’s DiGiCo Pad external control. Set its destination IP to this device’s network address and its send port to ‘This device receive UDP’. Set this app’s ‘Console receive UDP’ to the console’s receive port.")
                        Text("Names and send levels come from the console. No demo data. All-blue faders: −50 dB to +10 dB; no send on/off control.").font(.caption)
                    }
                    Section("Keep the bridge open") {
                        Text("Keep this app visible and this device powered during use. Auto-lock is disabled while hosting. Locking the device or switching apps into the background stops the bridge and releases reservations. Tap Start bridge after returning.")
                        Text("Use another iPad or iPhone for the musician browser. This version does not promise background or locked-screen hosting.").font(.caption)
                    }
                }
                .navigationTitle("Quantum Aux Bridge")
                .scrollDismissesKeyboard(.interactively)
            }.preferredColorScheme(.dark)
        }
        .onChange(of: phase) { _, value in
            if value == .background { model.stop(background: true) }
        }
    }
    private func port(_ title: String, _ binding: Binding<String>) -> some View {
        HStack { Text(title); Spacer(); TextField(title, text: binding).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 90) }
    }
}
