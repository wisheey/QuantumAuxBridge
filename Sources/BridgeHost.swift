import Foundation
import Network
import Darwin

// One queue owns TCP requests, UDP feedback, polling, and all lease mutations.
final class BridgeHost {
    let queue = DispatchQueue(label: "QuantumAuxBridge.network")
    private let core = BridgeCore()
    private var udp: Int32 = -1
    private var destination = sockaddr_in()
    private var source: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var pending: [String] = []
    private var cursor = 0
    private var nextPoll: TimeInterval = 0
    private var pollRevision = 0
    private var generation = 0
    private var config = BridgeConfig()
    private var lastStatus: TimeInterval = 0
    private var ready = false
    private var closingSockets = 0
    private var waitingStart: (() -> Void)?
    var onStatus: ((Bool, String, Int, Int) -> Void)?
    private lazy var router = BridgeRouter(core: core) { name in
        guard let root = Bundle.main.resourceURL else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent("Web").appendingPathComponent(name))
    }
    static func validate(_ config: BridgeConfig) throws {
        var address = in_addr()
        guard inet_pton(AF_INET, config.consoleIP, &address) == 1,
              let first = config.consoleIP.split(separator: ".").first.flatMap({ Int($0) }),
              first > 0, first < 224, config.consoleIP != "255.255.255.255",
              config.consolePort >= 1024, config.receivePort >= 1024, config.httpPort >= 1024 else {
            throw BridgeFailure(status: 400, message: "Enter a unicast console IPv4 address and ports from 1024 to 65535.")
        }
    }
    func start(_ config: BridgeConfig) {
        queue.async { [self] in
            stopInternal()
            waitingStart = { [weak self] in self?.open(config) }
            resumeStart()
        }
    }
    private func resumeStart() {
        guard closingSockets == 0, let action = waitingStart else { return }
        waitingStart = nil; action()
    }
    private func open(_ config: BridgeConfig) {
            self.config = config
            do {
                try Self.validate(config)
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { throw socketError() }
                udp = fd
                var local = sockaddr_in(); local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                local.sin_family = sa_family_t(AF_INET); local.sin_port = config.receivePort.bigEndian
                let result = withUnsafePointer(to: &local) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                guard result == 0, fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { throw socketError() }
                destination = sockaddr_in(); destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                destination.sin_family = sa_family_t(AF_INET); destination.sin_port = config.consolePort.bigEndian
                inet_pton(AF_INET, config.consoleIP, &destination.sin_addr)
                let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                let udpGeneration = generation
                readSource.setEventHandler { [weak self] in
                    guard let self = self, self.generation == udpGeneration else { return }; self.readUDP()
                }
                readSource.setCancelHandler { [weak self] in
                    Darwin.close(fd)
                    guard let self = self else { return }
                    self.closingSockets -= 1; self.resumeStart()
                }
                source = readSource; readSource.resume()
                core.transmit = { [weak self] packet in
                    guard let self = self else { throw BridgeFailure(status: 409, message: "Bridge stopped.") }
                    try self.sendUDP(packet)
                }
                let tcp = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: config.httpPort)!)
                listener = tcp
                let myGeneration = generation
                tcp.newConnectionHandler = { [weak self] connection in
                    guard let self = self, self.generation == myGeneration else { connection.cancel(); return }
                    self.accept(connection)
                }
                tcp.stateUpdateHandler = { [weak self] state in
                    guard let self = self, self.generation == myGeneration else { return }
                    switch state {
                    case .ready: self.ready = true; self.publish()
                    case .failed(let error): self.stopInternal(); self.report(false, "Server failed: \(error.localizedDescription)")
                    case .waiting(let error): self.report(false, "Starting · network waiting: \(error.localizedDescription)")
                    default: break
                    }
                }
                tcp.start(queue: queue)
                let poll = DispatchSource.makeTimerSource(queue: queue)
                poll.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
                poll.setEventHandler { [weak self] in
                    guard let self = self, self.generation == myGeneration else { return }; self.tick()
                }; timer = poll; poll.resume()
                report(false, "Starting bridge… Allow Local Network access when prompted.")
            } catch {
                stopInternal()
                report(false, (error as? BridgeFailure)?.message ?? error.localizedDescription)
            }
    }
    func stop(_ message: String = "Bridge stopped.") {
        queue.async { [self] in stopInternal(); report(false, message) }
    }
    private func stopInternal() {
        generation += 1; ready = false; waitingStart = nil
        timer?.cancel(); timer = nil
        listener?.cancel(); listener = nil
        for client in clients.values { client.cancel() }; clients.removeAll()
        if let source = source { closingSockets += 1; source.cancel(); self.source = nil }
        else if udp >= 0 { Darwin.close(udp) }
        udp = -1; core.transmit = nil; core.reset(); pending = []; cursor = 0; nextPoll = 0
    }
    private func socketError() -> BridgeFailure {
        BridgeFailure(status: 500, message: "Network socket: \(String(cString: strerror(errno)))")
    }
    private func sendUDP(_ data: Data) throws {
        guard udp >= 0 else { throw BridgeFailure(status: 409, message: "Bridge stopped.") }
        var address = destination
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(udp, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { throw socketError() }
    }
    private func readUDP() {
        guard udp >= 0 else { return }
        // Yield regularly so a busy socket cannot starve HTTP requests or stop events.
        for _ in 0..<64 {
            var buffer = [UInt8](repeating: 0, count: 65535)
            var sender = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, bytes.baseAddress, bytes.count, 0, $0, &length) }
                }
            }
            if count < 0 { return }
            guard sender.sin_addr.s_addr == destination.sin_addr.s_addr else { continue }
            core.receive(Data(buffer.prefix(count)))
        }
    }
    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if pollRevision != core.revision { pending = []; cursor = 0; nextPoll = 0; pollRevision = core.revision }
        if cursor >= pending.count, now >= nextPoll {
            pending = core.dueQueries(); cursor = 0; nextPoll = now + 0.25
        }
        if cursor < pending.count {
            let address = pending[cursor]; cursor += 1
            do { try sendUDP(OSC.message(address)) }
            catch { stopInternal(); report(false, "Console network send failed. Check Wi-Fi, permissions and IP settings, then start again."); return }
        }
        if now - lastStatus >= 1 { lastStatus = now; publish() }
    }
    private func publish() {
        report(ready, ready ? (core.connected ? "LIVE · receiving console feedback" : "Web server ready · waiting for console replies") : "Starting web server…")
    }
    private func report(_ running: Bool, _ message: String) {
        let inputs = core.inputCount ?? 0, leases = core.leases.count
        DispatchQueue.main.async { [weak self] in self?.onStatus?(running, message, inputs, leases) }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 128 else { connection.cancel(); return }
        let id = UUID(); clients[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .failed, .cancelled: self?.clients[id] = nil; default: break }
        }
        connection.start(queue: queue)
        receiveHTTP(connection, id, Data())
        queue.asyncAfter(deadline: .now() + 6) { [weak self, weak connection] in
            if self?.clients[id] != nil { connection?.cancel(); self?.clients[id] = nil }
        }
    }
    private func receiveHTTP(_ connection: NWConnection, _ id: UUID, _ accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self = self, self.clients[id] != nil else { return }
            var buffer = accumulated; if let data = data { buffer.append(data) }
            do {
                if let request = try HTTPRequest.parse(buffer) { self.respond(connection, id, self.router.handle(request)); return }
                if complete || error != nil { connection.cancel(); self.clients[id] = nil; return }
                self.receiveHTTP(connection, id, buffer)
            } catch let failure as BridgeFailure { self.respond(connection, id, .json(failure.status, ["error": failure.message])) }
            catch { self.respond(connection, id, .json(400, ["error": "Malformed request."])) }
        }
    }
    private func respond(_ connection: NWConnection, _ id: UUID, _ response: HTTPResponse) {
        connection.send(content: response.wire, completion: .contentProcessed { [weak self] _ in
            connection.cancel(); self?.clients[id] = nil
        })
    }
    static func localAddresses() -> [String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return [] }
        defer { freeifaddrs(first) }
        var result: [String] = []; var current = first
        while let pointer = current {
            let item = pointer.pointee; current = item.ifa_next
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0, item.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: item.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return Array(Set(result)).sorted()
    }
}
