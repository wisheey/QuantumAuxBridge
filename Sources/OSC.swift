import Foundation

enum OSC {
    enum Value { case float(Float), int(Int32), string(String)
        var number: Double? {
            switch self { case .float(let n): return Double(n); case .int(let n): return Double(n); case .string: return nil }
        }
    }
    enum Failure: Error { case malformed }
    static func padded(_ value: String) -> Data {
        var data = Data(value.utf8); data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
    static func message(_ address: String, _ value: Value? = nil) -> Data {
        var data = padded(address)
        guard let value = value else { data.append(padded(",")); return data }
        switch value {
        case .float(let number):
            data.append(padded(",f")); appendWord(number.bitPattern, to: &data)
        case .int(let number):
            data.append(padded(",i")); appendWord(UInt32(bitPattern: number), to: &data)
        case .string(let text): data.append(padded(",s")); data.append(padded(text))
        }
        return data
    }
    static func appendWord(_ n: UInt32, to data: inout Data) {
        data.append(contentsOf: [UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    }
    static func decode(_ packet: Data, depth: Int = 0) throws -> [(String, [Value])] {
        let bytes = [UInt8](packet)
        guard depth <= 8, bytes.count <= 65535 else { throw Failure.malformed }
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw Failure.malformed }
            return bytes[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        if bytes.starts(with: Array("#bundle\0".utf8)) {
            guard bytes.count >= 16 else { throw Failure.malformed }
            var offset = 16; var result: [(String, [Value])] = []
            while offset < bytes.count {
                let size = Int(try word(offset)); offset += 4
                guard size > 0, offset + size <= bytes.count else { throw Failure.malformed }
                result += try decode(Data(bytes[offset..<offset+size]), depth: depth + 1)
                offset += size
            }
            return result
        }
        var offset = 0
        func readString() throws -> String {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0),
                  let text = String(bytes: bytes[offset..<end], encoding: .utf8) else { throw Failure.malformed }
            offset = (end + 4) & ~3
            guard offset <= bytes.count else { throw Failure.malformed }
            return text
        }
        let address = try readString(), tags = try readString()
        guard address.hasPrefix("/"), tags.hasPrefix(",") else { throw Failure.malformed }
        var values: [Value] = []
        for tag in tags.dropFirst() {
            switch tag {
            case "f": values.append(.float(Float(bitPattern: try word(offset)))); offset += 4
            case "i": values.append(.int(Int32(bitPattern: try word(offset)))); offset += 4
            case "s": values.append(.string(try readString()))
            case "T": values.append(.int(1))
            case "F": values.append(.int(0))
            default: throw Failure.malformed
            }
        }
        return [(address, values)]
    }
}
