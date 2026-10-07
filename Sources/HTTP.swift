import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    static func parse(_ data: Data) throws -> HTTPRequest? {
        guard data.count <= 24576 else { throw BridgeFailure(status: 413, message: "Request too large.") }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16384 { throw BridgeFailure(status: 413, message: "Headers too large.") }; return nil
        }
        guard boundary.lowerBound <= 16384, let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw BridgeFailure(status: 400, message: "Invalid HTTP headers.")
        }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(String(first[2])), first[1].hasPrefix("/") else {
            throw BridgeFailure(status: 400, message: "Invalid request line.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else {
                throw BridgeFailure(status: 400, message: "Invalid header.")
            }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, headers[key] == nil else { throw BridgeFailure(status: 400, message: "Duplicate header.") }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil, let length = Int(headers["content-length"] ?? "0"), (0...8192).contains(length) else {
            throw BridgeFailure(status: 400, message: "Invalid body length.")
        }
        let start = boundary.upperBound
        guard data.count >= start + length else { return nil }
        let path = String(first[1].split(separator: "?", maxSplits: 1)[0])
        return HTTPRequest(method: String(first[0]), path: path, headers: headers, body: Data(data[start..<start+length]))
    }
    var token: String {
        let auth = headers["authorization"] ?? ""
        return auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : ""
    }
    func json() throws -> [String: Any] {
        guard headers["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw BridgeFailure(status: 400, message: "Expected a JSON object.")
        }
        return value
    }
    func checkOrigin() throws {
        // Browser requests must originate from the same host. Native clients may omit Origin.
        if let origin = headers["origin"] {
            guard let url = URLComponents(string: origin), url.scheme == "http", let host = url.host else {
                throw BridgeFailure(status: 403, message: "Cross-origin requests are not allowed.")
            }
            let authority = host + (url.port.map { ":\($0)" } ?? "")
            guard authority.lowercased() == headers["host"]?.lowercased() else {
                throw BridgeFailure(status: 403, message: "Cross-origin requests are not allowed.")
            }
        }
        if headers["sec-fetch-site"] == "cross-site" { throw BridgeFailure(status: 403, message: "Cross-site requests are not allowed.") }
    }
}
struct HTTPResponse {
    var status: Int
    var mime: String
    var body: Data
    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        HTTPResponse(status: status, mime: "application/json", body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8))
    }
    var wire: Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 413: "Content Too Large", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(mime); charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
final class BridgeRouter {
    let core: BridgeCore
    let asset: (String) -> Data?
    init(core: BridgeCore, asset: @escaping (String) -> Data?) { self.core = core; self.asset = asset }
    func handle(_ request: HTTPRequest) -> HTTPResponse {
        do {
            try request.checkOrigin()
            if request.method == "GET" {
                switch request.path {
                case "/api/mixes": return .json(200, core.catalog())
                case "/api/state": return .json(200, core.snapshot(try core.authorize(request.token)))
                case "/", "/app.js", "/style.css":
                    let file = request.path == "/" ? "index.html" : String(request.path.dropFirst())
                    guard let data = asset(file) else { throw BridgeFailure(status: 500, message: "Bundled UI asset missing.") }
                    return HTTPResponse(status: 200, mime: file.hasSuffix("html") ? "text/html" : file.hasSuffix("js") ? "text/javascript" : "text/css", body: data)
                default: return .json(404, ["error": "Not found. Setup is available only in the host app."])
                }
            }
            guard request.method == "POST" else { return .json(405, ["error": "Method not allowed."]) }
            let body = try request.json()
            switch request.path {
            case "/api/claim":
                guard Set(body.keys) == Set(["aux"]), let aux = BridgeCore.integer(body["aux"]) else {
                    throw BridgeFailure(status: 400, message: "Choose an aux.")
                }
                return .json(200, try core.claim(aux))
            case "/api/release": core.release(request.token); return .json(200, ["ok": true])
            case "/api/send": try core.write(try core.authorize(request.token), body); return .json(200, ["ok": true])
            default: return .json(404, ["error": "Not found."])
            }
        } catch let error as BridgeFailure { return .json(error.status, ["error": error.message]) }
        catch { return .json(400, ["error": "The request could not be completed."]) }
    }
}
