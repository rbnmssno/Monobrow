import Foundation
import Network

/// A one-purpose HTTP listener on 127.0.0.1 that receives the browser redirect at the end of the
/// Spotify login. It accepts connections from this Mac only and stops after the final answer.
final class LoopbackServer {
    struct Request {
        let path: String
        let query: [String: String]
    }

    struct Response {
        let status: Int
        let html: String
        /// True when the login flow is over and the listener can stop.
        let final: Bool
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.monobrow.Monobrow.loopback")
    private let handler: (Request) -> Response

    init(port: UInt16, handler: @escaping (Request) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw SpotifyError.invalidResponse }
        listener = try NWListener(using: parameters, on: endpointPort)
        self.handler = handler
    }

    /// `onState` is called once, on a background queue: success when listening, failure when the port is taken.
    func start(onState: @escaping (Result<Void, Error>) -> Void) {
        var reported = false
        listener.stateUpdateHandler = { state in
            guard !reported else { return }
            switch state {
            case .ready:
                reported = true
                onState(.success(()))
            case .failed(let error):
                reported = true
                onState(.failure(error))
            case .waiting(let error):
                reported = true
                onState(.failure(error))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    /// Frees the port. Answers already being sent still go out.
    func stop() {
        listener.cancel()
    }

    deinit {
        // An NWListener that is merely released keeps its port; it has to be cancelled.
        listener.cancel()
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let lineEnd = buffer.range(of: Data("\r\n".utf8)) {
                let line = String(decoding: buffer[buffer.startIndex..<lineEnd.lowerBound], as: UTF8.self)
                self.answer(connection, requestLine: line)
            } else if isComplete || error != nil || buffer.count > 32_768 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func answer(_ connection: NWConnection, requestLine: String) {
        let parts = requestLine.split(separator: " ")
        var response = Response(status: 400, html: "Bad request", final: false)
        if parts.count >= 2, parts[0] == "GET", let request = Self.parse(target: String(parts[1])) {
            response = handler(request)
        }
        let body = Data(response.html.utf8)
        let reason = response.status == 200 ? "OK" : (response.status == 404 ? "Not Found" : "Bad Request")
        let head = "HTTP/1.1 \(response.status) \(reason)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + "Connection: close\r\n\r\n"
        let isFinal = response.final
        let listener = self.listener
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
            // The login is over: stop listening even if the owner has already let go of the server.
            if isFinal { listener.cancel() }
        })
    }

    static func parse(target: String) -> Request? {
        guard let components = URLComponents(string: "http://127.0.0.1" + target) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return Request(path: components.path, query: query)
    }
}
