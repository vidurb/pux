import XCTest
@testable import PuxCore

final class WebSocketHandshakeTests: PuxTestCase {
    private func isPong(_ msg: String) -> Bool {
        guard let data = msg.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return dict["type"] as? String == "pong"
    }

    func testAwaitPongFailsWhenReceiveNeverPongs() async {
        let ws = MockWebSocketConnection()
        ws.inbound = ["{\"type\":\"envelope\",\"delivery_id\":\"d1\",\"envelope\":{}}"]
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 0.2, isPong: isPong)
        guard case .failed(let deferred, .pongTimeout) = outcome else {
            return XCTFail("expected pong timeout")
        }
        XCTAssertEqual(deferred.count, 1)
    }

    func testAwaitPongSucceedsOnPong() async {
        let ws = MockWebSocketConnection()
        ws.inbound = ["{\"type\":\"pong\"}"]
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 1.0, isPong: isPong)
        guard case .completed(let deferred) = outcome else {
            return XCTFail("expected success")
        }
        XCTAssertTrue(deferred.isEmpty)
    }

    func testEnvelopeThenPongIsDeferredNotDropped() async {
        let ws = MockWebSocketConnection()
        ws.inbound = [
            "{\"type\":\"envelope\",\"delivery_id\":\"d1\",\"envelope\":{}}",
            "{\"type\":\"pong\"}",
        ]
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 1.0, isPong: isPong)
        guard case .completed(let deferred) = outcome else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(deferred.count, 1)
    }

    func testHandshakeReturnsDeferredBeforeSlowFollowUpWork() async throws {
        let ws = MockWebSocketConnection()
        ws.inbound = [
            "{\"type\":\"envelope\",\"delivery_id\":\"d1\",\"envelope\":{}}",
            "{\"type\":\"pong\"}",
        ]
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 1.0, isPong: isPong)
        guard case .completed(let deferred) = outcome else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(deferred.count, 1)
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testHandshakeFailureRetainsDeferredForAllReasons() async {
        let ws = MockWebSocketConnection()
        ws.inbound = ["{\"type\":\"envelope\",\"delivery_id\":\"d1\",\"envelope\":{}}"]
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 0.2, isPong: isPong)
        guard case .failed(let deferred, _) = outcome else {
            return XCTFail("expected failure")
        }
        XCTAssertEqual(deferred.count, 1)
    }

    func testStalledSendFailsWithinHandshakeTimeout() async {
        let ws = MockWebSocketConnection()
        ws.blockNextSend()
        let start = Date()
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 0.25, isPong: { _ in false })
        guard case .failed(_, .sendTimeout) = outcome else {
            return XCTFail("expected send timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
    }

    func testStalledReceiveFailsWithinHandshakeTimeout() async {
        let ws = MockWebSocketConnection()
        ws.blockNextReceive()
        let start = Date()
        let outcome = await DesktopDeliveryService.performWebSocketHandshake(ws: ws, timeout: 0.25, isPong: { _ in false })
        guard case .failed(_, .pongTimeout) = outcome else {
            return XCTFail("expected pong timeout")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
    }

    func testKeepAlivePingSendIsBounded() async {
        let ws = MockWebSocketConnection()
        ws.blockNextSend()
        let start = Date()
        do {
            try await DesktopDeliveryService.sendKeepAlivePing(ws: ws, timeout: 0.25)
            XCTFail("expected send timeout")
        } catch let error as ApiError {
            XCTAssertEqual(error, ApiError.networkError("WebSocket send timeout"))
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.6)
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }
}
