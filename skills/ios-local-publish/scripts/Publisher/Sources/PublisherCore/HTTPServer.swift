import Foundation
import Network

public struct HTTPResponse {
    let status: Int
    let type: String
    let data: Data
    let length: Int
    public init(_ status: Int = 200, json value: Any) {
        self.status = status; type = "application/json"; data = (try? json(value)) ?? Data("{}".utf8); length = data.count
    }
    public init(_ status: Int = 200, type: String, data: Data, length: Int? = nil) { self.status = status; self.type = type; self.data = data; self.length = length ?? data.count }
}

public final class HTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.bitcreative.publish.http", attributes: .concurrent)
    private let handler: @Sendable (String, String, [String: String], Data) async -> HTTPResponse
    public init(handler: @escaping @Sendable (String, String, [String: String], Data) async -> HTTPResponse) { self.handler = handler }
    public func start(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            let timeout = DispatchWorkItem { connection.cancel() }
            self.queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            self.receive(connection, buffer: Data(), timeout: timeout)
        }
        listener.stateUpdateHandler = { state in
            if case let .failed(error) = state { progress("HTTP listener failed: \(error)") }
        }
        listener.start(queue: queue)
    }
    private func receive(_ connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard buffer.count <= 131072 else { self.send(connection, response: HTTPResponse(413, json: ["error": "Request too large"])); return }
            if let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ").map(String.init)
                guard first.count == 3 else { connection.cancel(); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon].lowercased()
                    guard headers[key] == nil else { connection.cancel(); return }
                    headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? -1
                guard length >= 0 && length <= 65536 && headers["transfer-encoding"] == nil else { connection.cancel(); return }
                let body = buffer[split.upperBound...]
                if body.count >= length {
                    timeout.cancel()
                    let handler = self.handler
                    Task {
                        let response = await handler(first[0], first[1], headers, Data(body.prefix(length)))
                        self.send(connection, response: response)
                    }
                    return
                }
            }
            if complete { connection.cancel() } else { self.receive(connection, buffer: buffer, timeout: timeout) }
        }
    }
    private func send(_ connection: NWConnection, response: HTTPResponse) {
        let header = "HTTP/1.1 \(response.status) Response\r\nContent-Type: \(response.type)\r\nContent-Length: \(response.length)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        connection.send(content: Data(header.utf8) + response.data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
