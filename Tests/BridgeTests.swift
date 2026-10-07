import XCTest
@testable import QuantumAuxBridgeCore

final class BridgeTests: XCTestCase {
    var clock: Double = 100
    var core: BridgeCore!
    override func setUp() {
        clock = 100; core = BridgeCore(now: { [unowned self] in self.clock }); core.reset()
        reply("/Console/Input_Channels", .int(2))
        core.receive(modes([2, 1]))
        reply("/Console/Name", .string("Test console"))
        reply("/Input_Channels/1/Channel_Input/name", .string("Vocal"))
        reply("/Input_Channels/2/Channel_Input/name", .string("Guitar"))
        reply("/Aux_Outputs/1/Buss_Trim/name", .string("IEM"))
        reply("/Aux_Outputs/2/Buss_Trim/name", .string("Wedge"))
        reply(BridgeCore.address(1, 1, "level"), .float(-10))
        reply(BridgeCore.address(1, 1, "pan"), .float(0.5))
    }
    func reply(_ path: String, _ value: OSC.Value) { core.receive(OSC.message(path, value)) }
    func modes(_ values: [Int32]) -> Data {
        var data = OSC.padded("/Console/Aux_Outputs/modes") + OSC.padded("," + String(repeating: "i", count: values.count))
        for n in values { OSC.appendWord(UInt32(bitPattern: n), to: &data) }; return data
    }
    func payload(_ value: Double, field: String = "level") -> [String: Any] {
        ["channel": 1, "field": field, "value": value, "revision": core.revision]
    }
    func testExclusiveLeaseAndRelease() throws {
        let token = try XCTUnwrap(core.claim(1)["token"] as? String)
        XCTAssertThrowsError(try core.claim(1))
        XCTAssertEqual(try core.authorize(token), 1)
        core.release("wrong-token"); XCTAssertThrowsError(try core.claim(1))
        core.release(token)
        let next = try XCTUnwrap(core.claim(1)["token"] as? String)
        core.release(token); XCTAssertEqual(try core.authorize(next), 1)
        XCTAssertThrowsError(try core.authorize(token))
    }
    func testHeartbeatAndExpiry() throws {
        let token = try XCTUnwrap(core.claim(1)["token"] as? String)
        clock += 20; _ = try core.authorize(token)
        clock += 20; _ = try core.authorize(token)
        clock += 31; XCTAssertThrowsError(try core.authorize(token)); XCTAssertTrue(core.leases.isEmpty)
    }
    func testRangeAndNoInventedReadback() throws {
        var writes: [Data] = []; core.transmit = { writes.append($0) }
        try core.write(1, payload(-50)); clock += 0.2; try core.write(1, payload(10))
        let decoded = try OSC.decode(writes[1]); XCTAssertEqual(decoded.first?.1.first?.number, 10)
        XCTAssertThrowsError(try core.write(1, payload(-50.5)))
        XCTAssertThrowsError(try core.write(1, payload(10.5)))
        XCTAssertThrowsError(try core.write(1, payload(0, field: "on")))
        let channels = try XCTUnwrap(core.snapshot(1)["channels"] as? [[String: Any]])
        let fields = try XCTUnwrap(channels[0]["fields"] as? [String: [String: Any]])
        XCTAssertEqual(fields["level"]?["value"] as? Double, -10)
        reply(BridgeCore.address(1, 1, "level"), .float(10))
        XCTAssertEqual(writes.count, 2)
    }
    func testStaleAndUnknownFeedbackBlocked() throws {
        core.transmit = { _ in }
        XCTAssertThrowsError(try core.write(2, payload(0)))
        clock += 31; reply("/Console/Name", .string("Test console"))
        XCTAssertTrue(core.connected); XCTAssertThrowsError(try core.write(1, payload(0)))
    }
    func testSessionChangeInvalidatesLeaseAndRevision() throws {
        let token = try XCTUnwrap(core.claim(1)["token"] as? String), revision = core.revision
        core.receive(OSC.message("/Console/Session/!"))
        XCTAssertGreaterThan(core.revision, revision); XCTAssertThrowsError(try core.authorize(token)); XCTAssertFalse(core.connected)
    }
    func testTopologyChangeClearsFeedback() throws {
        core.transmit = { _ in }; core.receive(modes([1, 1]))
        XCTAssertThrowsError(try core.write(1, payload(0)))
        XCTAssertThrowsError(try core.write(1, payload(0.5, field: "pan")))
    }
    func testQueriesAreReadOnlyAndActiveAuxOnly() throws {
        let initial = core.dueQueries()
        XCTAssertTrue(initial.allSatisfy { $0.hasSuffix("/?") }); XCTAssertFalse(initial.contains { $0.contains("Aux_Send") })
        _ = try core.claim(1)
        let active = core.dueQueries()
        XCTAssertTrue(active.contains("/Input_Channels/1/Aux_Send/1/send_level/?"))
        XCTAssertFalse(active.contains { $0.contains("/Aux_Send/2/") })
        XCTAssertTrue(core.dueQueries().isEmpty)
    }
    func testRejectNonFiniteAndBooleanValues() {
        core.transmit = { _ in }
        XCTAssertThrowsError(try core.write(1, payload(.nan)))
        var body = payload(0); body["value"] = true
        XCTAssertThrowsError(try core.write(1, body)); XCTAssertNil(BridgeCore.integer(true))
    }
    func testMalformedOSCDoesNotChangeState() {
        let old = core.received; core.receive(Data([0, 1, 2])); XCTAssertEqual(core.received, old)
    }
    func testHTTPFragmentationAndDuplicateLength() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("POST /api/claim HTTP/1.1\r\nHost: phone:8765\r\nContent-Length: 9\r\n\r\n{".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
    }
    func testHTTPClaimConflictAuthorizationAndOrigin() throws {
        let router = BridgeRouter(core: core, asset: { _ in Data("asset".utf8) })
        func request(_ method: String, _ path: String, _ body: String = "", token: String = "", origin: String = "http://phone:8765") throws -> HTTPRequest {
            let raw = "\(method) \(path) HTTP/1.1\r\nHost: phone:8765\r\nOrigin: \(origin)\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            return try XCTUnwrap(HTTPRequest.parse(Data(raw.utf8)))
        }
        let response = router.handle(try request("POST", "/api/claim", "{\"aux\":1}"))
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let token = try XCTUnwrap(json["token"] as? String)
        XCTAssertEqual(router.handle(try request("POST", "/api/claim", "{\"aux\":1}")).status, 409)
        XCTAssertEqual(router.handle(try request("GET", "/api/state", token: token)).status, 200)
        XCTAssertEqual(router.handle(try request("GET", "/api/state")).status, 403)
        XCTAssertEqual(router.handle(try request("POST", "/api/claim", "{\"aux\":2}", origin: "http://evil.test")).status, 403)
        XCTAssertEqual(router.handle(try request("GET", "/setup")).status, 404)
        XCTAssertEqual(router.handle(try request("GET", "/../Info.plist")).status, 404)
    }
}
