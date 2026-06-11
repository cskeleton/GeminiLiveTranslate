import Foundation
import Network
import CryptoKit
import os

/// Minimal WebSocket server for broadcasting latency data to IINA plugins.
/// One-way: server → clients only. No external dependencies.
final class WebSocketServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var upgradedConnections: Set<ObjectIdentifier> = []
    private var lastBroadcastJSON: String = "{\"latency\":0,\"isTranslating\":false}"
    private var broadcastTimer: DispatchSourceTimer?
    private let lock = OSAllocatedUnfairLock()

    init(port: UInt16 = 18930) {
        self.port = port
    }

    /// Start listening for connections.
    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.log("Listener failed: \(error)")
                self?.stop()
            default:
                break
            }
        }

        listener.start(queue: .global(qos: .utility))
        log("WebSocket server started on port \(port)")
    }

    /// Start periodic broadcasting (every 1 second). Safe to call from any thread.
    func startBroadcasting() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let json = self.lock.withLock { self.lastBroadcastJSON }
            self.broadcast(json)
        }
        timer.resume()
        broadcastTimer = timer
    }

    /// Stop the server, timer, and close all connections.
    func stop() {
        broadcastTimer?.cancel()
        broadcastTimer = nil
        listener?.cancel()
        listener = nil

        lock.withLock {
            for conn in connections {
                conn.cancel()
            }
            connections.removeAll()
            upgradedConnections.removeAll()
        }
        log("WebSocket server stopped")
    }

    /// Broadcast a JSON text message to all connected and upgraded clients.
    func broadcast(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        let frame = encodeTextFrame(data)
        lock.withLock {
            lastBroadcastJSON = message
        }
        sendFrameToAll(frame)
    }

    /// Update the latency data and broadcast immediately. Thread-safe.
    func updateLatency(_ json: String) {
        broadcast(json)
    }

    private func sendFrameToAll(_ frame: Data) {

        lock.withLock {
            connections = connections.filter { $0.state == .ready }
            for conn in connections {
                let id = ObjectIdentifier(conn)
                guard upgradedConnections.contains(id) else { continue }
                conn.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        lock.withLock {
            connections.append(connection)
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveInitialData(connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .utility))
    }

    private func receiveInitialData(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            if request.lowercased().contains("upgrade: websocket") {
                self.handleWebSocketUpgrade(connection, request: request)
            } else {
                self.handleHTTPRequest(connection)
            }
        }
    }

    private func handleWebSocketUpgrade(_ connection: NWConnection, request: String) {
        // Extract Sec-WebSocket-Key
        guard let key = extractHeader(request, name: "Sec-WebSocket-Key") else {
            connection.cancel()
            return
        }

        // Compute Sec-WebSocket-Accept
        let magicGUID = "258EAFA5-E914-47DA-95CA-5AB9FC3ED4A5"
        let combined = key + magicGUID
        let sha1 = Insecure.SHA1.hash(data: combined.data(using: .utf8)!)
        let accept = Data(sha1).base64EncodedString()

        let response = "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock {
                self.upgradedConnections.insert(ObjectIdentifier(connection))
            }
            self.log("Client upgraded to WebSocket")
            // Start listening for client messages (to detect disconnect)
            self.listenForClose(connection)
        })
    }

    private func handleHTTPRequest(_ connection: NWConnection) {
        // Return current latency data as HTTP JSON (used by IINA plugin polling)
        let body = lock.withLock { lastBroadcastJSON }
        let response = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "Connection: close\r\n" +
            "Access-Control-Allow-Origin: *\r\n\r\n\(body)"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func listenForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, _ in
            if isComplete {
                self?.removeConnection(connection)
            } else {
                // Continue listening
                self?.listenForClose(connection)
            }
        }
    }

    private func removeConnection(_ connection: NWConnection) {
        lock.withLock {
            let id = ObjectIdentifier(connection)
            upgradedConnections.remove(id)
            connections.removeAll { ObjectIdentifier($0) == id }
        }
        connection.cancel()
    }

    // MARK: - WebSocket Frame Encoding

    /// Encode data as an unmasked WebSocket text frame (server → client).
    private func encodeTextFrame(_ payload: Data) -> Data {
        var frame = Data()
        let length = payload.count

        // Byte 0: FIN=1, opcode=1 (text)
        frame.append(0x81)

        // Byte 1+: payload length (no mask bit for server→client)
        if length < 126 {
            frame.append(UInt8(length))
        } else if length < 65536 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((length >> (i * 8)) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    // MARK: - Helpers

    private func extractHeader(_ request: String, name: String) -> String? {
        let lowerName = name.lowercased()
        for line in request.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == lowerName {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func log(_ message: String) {
        print("[WebSocketServer] \(message)")
    }
}
