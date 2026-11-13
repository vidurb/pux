import Foundation
import XCTest
@testable import PuxCore

final class WebSocketLifecycleTests: XCTestCase {
    func testDisconnectBeforeConnectPreventsLateConnection() async {
        let socket = NativeWebSocketConnection(url: URL(string: "ws://127.0.0.1:1")!)
        socket.disconnect()
        socket.connect()
        do {
            try await socket.sendText("test")
            XCTFail("A disconnected socket must not reconnect")
        } catch {
            XCTAssertTrue(String(describing: error).contains("WebSocket not connected"))
        }
    }

    func testConcurrentConnectAndDisconnectAreSafe() async {
        for _ in 0..<100 {
            let socket = NativeWebSocketConnection(url: URL(string: "ws://127.0.0.1:1")!)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { socket.connect() }
                group.addTask { socket.disconnect() }
            }
            socket.disconnect()
            socket.connect()
            do {
                try await socket.sendText("test")
                XCTFail("A disconnected socket must not reconnect")
            } catch {
                XCTAssertTrue(String(describing: error).contains("WebSocket not connected"))
            }
        }
    }
}
