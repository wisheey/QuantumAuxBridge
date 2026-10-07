import Foundation
import CoreFoundation

struct BridgeFailure: Error { let status: Int; let message: String }
struct BridgeConfig: Codable {
    var consoleIP = ""
    var consolePort: UInt16 = 8000
    var receivePort: UInt16 = 9000
    var httpPort: UInt16 = 8765
}

// All access belongs to BridgeHost.queue. No network callback mutates this elsewhere.
final class BridgeCore {
    struct Aux { var name: String?; var mode: Int }
    struct Cell { let value: Double; let at: TimeInterval }
    struct Lease { let token: String; var expires: TimeInterval }
    let now: () -> TimeInterval
    var transmit: ((Data) throws -> Void)?
    private(set) var revision = 0
    private(set) var inputs: [Int: String] = [:]
    private(set) var inputCount: Int?
    private(set) var auxes: [Int: Aux] = [:]
    private(set) var modes: [Int]?
    private(set) var leases: [Int: Lease] = [:]
    private var cells: [String: Cell] = [:]
    private var active: [Int: TimeInterval] = [:]
    private var queries: [String: TimeInterval] = [:]
    private var writes: [String: TimeInterval] = [:]
    private var lastReply: TimeInterval?
    private var consoleName: String?
    private(set) var received = 0
    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    var connected: Bool { lastReply.map { now() - $0 < 12 } ?? false }
    func reset() {
        revision += 1; inputs.removeAll(); inputCount = nil; auxes.removeAll(); modes = nil
        cells.removeAll(); active.removeAll(); queries.removeAll(); writes.removeAll(); leases.removeAll()
        lastReply = nil; consoleName = nil; received = 0
    }
    static func address(_ ch: Int, _ aux: Int, _ field: String) -> String {
        "/Input_Channels/\(ch)/Aux_Send/\(aux)/send_\(field)"
    }
    func expire() {
        for (id, lease) in Array(leases) where lease.expires <= now() { leases[id] = nil; active[id] = nil }
    }
    func connection() -> [String: Any] {
        ["connected": connected, "discovered": inputCount != nil && modes != nil,
         "console_name": consoleName as Any? ?? NSNull(), "received_messages": received,
         "message": connected ? "Receiving live console data." : "Waiting for console OSC replies. Check DiGiCo Pad, IP addresses and ports."]
    }
    private func auxInfo(_ id: Int) -> [String: Any] {
        let aux = auxes[id]
        return ["id": id, "name": aux?.name as Any? ?? NSNull(), "stereo": aux?.mode == 2,
                "supported": aux.map { [1, 2].contains($0.mode) } ?? false, "mode": aux?.mode ?? 0]
    }
    func catalog() -> [String: Any] {
        expire()
        return ["connection": connection(), "lease_seconds": 30, "auxes": auxes.keys.sorted().map { id -> [String: Any] in
            var item = auxInfo(id); let aux = auxes[id]!
            item["occupied"] = leases[id] != nil
            item["available"] = connected && [1, 2].contains(aux.mode) && aux.name != nil && leases[id] == nil
            return item
        }]
    }
    func claim(_ id: Int) throws -> [String: Any] {
        expire()
        guard let aux = auxes[id] else { throw BridgeFailure(status: 400, message: "Choose an available aux.") }
        guard connected, [1, 2].contains(aux.mode), aux.name != nil else {
            throw BridgeFailure(status: 409, message: "This aux is not ready. Wait for console feedback.")
        }
        guard leases[id] == nil else { throw BridgeFailure(status: 409, message: "This mix is already in use.") }
        // SystemRandomNumberGenerator uses the platform's secure random source.
        var random = SystemRandomNumberGenerator()
        let token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &random)) }.joined()
        leases[id] = Lease(token: token, expires: now() + 30); active[id] = now()
        return ["token": token, "aux": id, "lease_seconds": 30]
    }
    func authorize(_ token: String) throws -> Int {
        expire()
        if let pair = leases.first(where: { $0.value.token == token }) {
            leases[pair.key]?.expires = now() + 30; return pair.key
        }
        throw BridgeFailure(status: 403, message: "Your mix reservation has ended. Choose an available mix.")
    }
    func release(_ token: String) {
        expire()
        if let pair = leases.first(where: { $0.value.token == token }) { leases[pair.key] = nil; active[pair.key] = nil }
    }
    func snapshot(_ aux: Int) -> [String: Any] {
        active[aux] = now()
        let channels: [[String: Any]] = (1..<(1 + (inputCount ?? 0))).map { ch in
            var fields: [String: Any] = [:]
            for field in ["level", "pan"] {
                let cell = cells[Self.address(ch, aux, field)]
                fields[field] = ["value": cell?.value as Any? ?? NSNull(),
                                 "fresh": cell.map { connected && now() - $0.at < 30 } ?? false]
            }
            return ["id": ch, "name": inputs[ch] as Any? ?? NSNull(), "group": "Inputs", "fields": fields]
        }
        return ["mode": "live", "revision": revision, "connection": connection(), "aux": auxInfo(aux),
                "max_db": 10, "channels": channels]
    }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    static func integer(_ value: Any?) -> Int? {
        guard let n = number(value), n.rounded() == n, abs(n) < 1_000_000_000 else { return nil }; return Int(n)
    }
    func write(_ aux: Int, _ body: [String: Any]) throws {
        guard Set(body.keys) == Set(["channel", "field", "value", "revision"]),
              let ch = Self.integer(body["channel"]), let field = body["field"] as? String,
              ["level", "pan"].contains(field), let value = Self.number(body["value"]) else {
            throw BridgeFailure(status: 400, message: "Invalid send request.")
        }
        guard Self.integer(body["revision"]) == revision else {
            throw BridgeFailure(status: 409, message: "Console session changed. Refresh before changing a send.")
        }
        guard let info = auxes[aux], [1, 2].contains(info.mode), ch > 0, ch <= (inputCount ?? 0),
              field != "pan" || info.mode == 2 else { throw BridgeFailure(status: 400, message: "Unavailable input, aux or pan.") }
        guard (field == "level" ? (-50...10).contains(value) : (0...1).contains(value)) else {
            throw BridgeFailure(status: 400, message: "Send value exceeds its allowed range.")
        }
        let key = Self.address(ch, aux, field)
        guard connected, let cell = cells[key], now() - cell.at < 30, inputs[ch] != nil, info.name != nil else {
            throw BridgeFailure(status: 409, message: "Current console feedback or names are missing. Control paused.")
        }
        guard let send = transmit else { throw BridgeFailure(status: 409, message: "Console connection is not open.") }
        guard now() - (writes[key] ?? -1000) >= 0.08 else { throw BridgeFailure(status: 429, message: "Changes are arriving too quickly.") }
        try send(OSC.message(key, .float(Float(value)))); writes[key] = now()
        // Never invent feedback. Only an incoming console packet updates cells.
    }
    func receive(_ packet: Data) {
        guard let messages = try? OSC.decode(packet) else { return }
        for (address, args) in messages {
            received += 1
            if address == "/Console/Session/!" { reset(); continue }
            var valid = false
            if address == "/Console/Name", args.count == 1, case .string(let name) = args[0] {
                consoleName = String(name.prefix(256)); valid = true
            } else if address == "/Console/Input_Channels", args.count == 1, case .int(let n) = args[0], (0...256).contains(n) {
                if let count = inputCount, count != Int(n) { revision += 1; cells.removeAll() }
                inputCount = Int(n); inputs = inputs.filter { $0.key <= Int(n) }; valid = true
            } else if address == "/Console/Aux_Outputs/modes", args.count <= 128 {
                let values = args.compactMap { value -> Int? in
                    if case .int(let n) = value, (0...8).contains(n) { return Int(n) }; return nil
                }
                if values.count == args.count {
                    if let old = modes, old != values { revision += 1; cells.removeAll(); leases.removeAll(); active.removeAll() }
                    modes = values
                    auxes = Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset + 1, Aux(name: auxes[$0.offset + 1]?.name, mode: $0.element)) })
                    valid = true
                }
            } else {
                let p = address.split(separator: "/").map(String.init)
                if p.count == 4, args.count == 1, case .string(let name) = args[0], let id = Int(p[1]) {
                    if p[0] == "Input_Channels", p[2] == "Channel_Input", p[3] == "name", id > 0, id <= (inputCount ?? 0) {
                        inputs[id] = String(name.prefix(256)); valid = true
                    } else if p[0] == "Aux_Outputs", p[2] == "Buss_Trim", p[3] == "name", auxes[id] != nil {
                        auxes[id]?.name = String(name.prefix(256)); valid = true
                    }
                } else if p.count == 5, p[0] == "Input_Channels", p[2] == "Aux_Send", let ch = Int(p[1]), let aux = Int(p[3]),
                          ch > 0, ch <= (inputCount ?? 0), auxes[aux] != nil, args.count == 1,
                          let n = args[0].number, n.isFinite,
                          (p[4] == "send_level" && (-150...10).contains(n)) || (p[4] == "send_pan" && (0...1).contains(n)) {
                    cells[address] = Cell(value: n, at: now()); valid = true
                }
            }
            if valid { lastReply = now() }
        }
    }
    // Scheduler drains at most one query per 2 ms; a slow console cannot cause an unbounded backlog.
    func dueQueries() -> [String] {
        expire()
        var candidates: [(String, Double)] = [("/Console/Name/?", 3), ("/Console/Channels/?", 5), ("/Console/Aux_Outputs/modes/?", 5)]
        for id in auxes.keys.sorted() { candidates.append(("/Aux_Outputs/\(id)/Buss_Trim/name/?", auxes[id]?.name == nil ? 2 : 15)) }
        for ch in 1..<(1 + (inputCount ?? 0)) { candidates.append(("/Input_Channels/\(ch)/Channel_Input/name/?", inputs[ch] == nil ? 2 : 15)) }
        for aux in active.keys.sorted() where now() - active[aux]! <= 15 && auxes[aux] != nil {
            for ch in 1..<(1 + (inputCount ?? 0)) {
                for field in ["level", "pan"] where field != "pan" || auxes[aux]?.mode == 2 {
                    candidates.append((Self.address(ch, aux, field) + "/?", 4))
                }
            }
        }
        return candidates.compactMap { address, interval in
            guard now() - (queries[address] ?? -1000) >= interval else { return nil }
            queries[address] = now(); return address
        }
    }
}
