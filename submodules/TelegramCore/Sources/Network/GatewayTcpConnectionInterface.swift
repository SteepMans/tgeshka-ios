import Foundation
import Network

import MtProtoKit
import SwiftSignalKit

// TGeshka: an MTProto connection carried over one WebSocket to the gateway.
// MtProtoKit keeps building the same byte stream it would write to a TCP socket
// (obfuscated2 init + abridged, empty secret); this interface only moves those
// bytes inside binary WebSocket messages. The DC address MtProtoKit wanted goes
// to the gateway as `?a=IPv4:port`. Protocol: SteepMans/api-gateway
// docs/tg-protocol-v1.md.

@available(iOS 13.0, macOS 14.0, *)
final class GatewayTcpConnectionInterface: NSObject, MTTcpConnectionInterface {
    private struct ReadRequest {
        let length: Int
        let tag: Int
    }

    private final class ExecutingReadRequest {
        let request: ReadRequest
        var data: Data
        var readyLength: Int = 0

        init(request: ReadRequest) {
            self.request = request
            self.data = Data(count: request.length)
        }
    }

    private final class Impl {
        private let queue: Queue

        private weak var delegate: MTTcpConnectionInterfaceDelegate?
        private let delegateQueue: DispatchQueue

        private var connection: NWConnection?
        private var reportedDisconnection = false
        private var countedAsOpen = false
        private var registrationId: Int?

        private var currentInterfaceIsWifi = true
        private var connectTimeoutTimer: SwiftSignalKit.Timer?
        private var connectStart: CFAbsoluteTime = 0

        private var usageCalculationInfo: MTNetworkUsageCalculationInfo?
        private var networkUsageManager: MTNetworkUsageManager?

        private var inbound = Data()
        private var readRequests: [ReadRequest] = []
        private var currentReadRequest: ExecutingReadRequest?

        private var getLogPrefix: (() -> String)?
        private var instanceId: String = ""
        private var logId: String = ""

        init(queue: Queue, delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
            self.queue = queue
            self.delegate = delegate
            self.delegateQueue = delegateQueue
            self.instanceId = String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16)
            self.logId = "[GwWs#\(self.instanceId)]"
        }

        deinit {
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
            }
            if let registrationId = self.registrationId {
                TGeshkaGateway.shared.unregisterConnection(registrationId)
            }
            if self.countedAsOpen {
                TGeshkaGateway.shared.connectionClosed()
            }
        }

        func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
            if self.usageCalculationInfo !== usageCalculationInfo {
                self.usageCalculationInfo = usageCalculationInfo
                if let usageCalculationInfo = usageCalculationInfo {
                    self.networkUsageManager = MTNetworkUsageManager(info: usageCalculationInfo)
                } else {
                    self.networkUsageManager = nil
                }
            }
        }

        func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
            self.getLogPrefix = getLogPrefix
        }

        private static func isIPv4(_ host: String) -> Bool {
            var address = in_addr()
            return host.withCString { inet_pton(AF_INET, $0, &address) } == 1
        }

        private static func streamUrl(base: String, host: String, port: UInt16) -> URL? {
            guard var components = URLComponents(string: base) else {
                return nil
            }
            if isIPv4(host) {
                var items = components.queryItems ?? []
                items.append(URLQueryItem(name: "a", value: "\(host):\(port)"))
                components.queryItems = items
            }
            return components.url
        }

        func connect(host: String, port: UInt16, timeout: Double) {
            if self.connection != nil {
                Logger.shared.log("GwWs", "\(self.logId) connect to \(host):\(port) ignored: a connection already exists")
                return
            }
            if let logPrefix = self.getLogPrefix?(), !logPrefix.isEmpty {
                self.logId = "[GwWs#\(self.instanceId) \(logPrefix) \(host):\(port)]"
            } else {
                self.logId = "[GwWs#\(self.instanceId) \(host):\(port)]"
            }

            let gateway = TGeshkaGateway.shared
            let settings = gateway.settings
            let token = settings.token
            if token.isEmpty {
                gateway.reportError(.noKey, technical: "no gateway access key")
                self.cancelWithError(error: nil, reason: "no gateway key")
                return
            }
            guard let url = Impl.streamUrl(base: gateway.effectiveUrl, host: host, port: port) else {
                gateway.reportError(.badUrl, technical: "bad gateway url")
                self.cancelWithError(error: nil, reason: "bad gateway url")
                return
            }

            let webSocketOptions = NWProtocolWebSocket.Options()
            webSocketOptions.autoReplyPing = true
            webSocketOptions.maximumMessageSize = 4 * 1024 * 1024
            webSocketOptions.setAdditionalHeaders([
                (name: "Authorization", value: "Bearer \(token)"),
                (name: "X-TGeshka-Client", value: TGeshkaGateway.clientHeader)
            ])

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 15
            tcpOptions.keepaliveCount = 3
            tcpOptions.keepaliveInterval = 5

            let parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: tcpOptions)
            parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

            let connection = NWConnection(to: .url(url), using: parameters)
            self.connection = connection
            self.registrationId = gateway.registerConnection(disconnect: { [weak self, queue = self.queue] in
                queue.async {
                    self?.cancelWithError(error: nil, reason: "gateway settings changed")
                }
            })

            let queue = self.queue
            connection.stateUpdateHandler = { [weak self] state in
                queue.async {
                    self?.stateUpdated(state: state)
                }
            }
            connection.pathUpdateHandler = { [weak self] path in
                queue.async {
                    self?.currentInterfaceIsWifi = !path.usesInterfaceType(.cellular)
                }
            }
            connection.viabilityUpdateHandler = { [weak self] isViable in
                queue.async {
                    if !isViable {
                        self?.cancelWithError(error: nil, reason: "connection is no longer viable")
                    }
                }
            }

            self.connectTimeoutTimer = SwiftSignalKit.Timer(timeout: max(timeout, 15.0), repeat: false, completion: { [weak self] in
                guard let self = self else {
                    return
                }
                self.connectTimeoutTimer = nil
                TGeshkaGateway.shared.reportError(.timeout, technical: "connect timeout after \(Int(max(timeout, 15.0))) s")
                self.cancelWithError(error: nil, reason: "connect timeout")
            }, queue: self.queue)
            self.connectTimeoutTimer?.start()

            Logger.shared.log("GwWs", "\(self.logId) opening gateway WebSocket")
            self.connectStart = CFAbsoluteTimeGetCurrent()
            connection.start(queue: self.queue.queue)
        }

        private func stateUpdated(state: NWConnection.State) {
            guard self.connection != nil else {
                return
            }
            switch state {
            case .ready:
                if let connectTimeoutTimer = self.connectTimeoutTimer {
                    self.connectTimeoutTimer = nil
                    connectTimeoutTimer.invalidate()
                }
                if let path = self.connection?.currentPath {
                    self.currentInterfaceIsWifi = !path.usesInterfaceType(.cellular)
                }
                let handshakeMs = Int((CFAbsoluteTimeGetCurrent() - self.connectStart) * 1000.0)
                Logger.shared.log("GwWs", "\(self.logId) Gateway WebSocket opened in \(handshakeMs) ms")
                if !self.countedAsOpen {
                    self.countedAsOpen = true
                    TGeshkaGateway.shared.connectionOpened(handshakeMs: handshakeMs)
                }
                let delegate = self.delegate
                self.delegateQueue.async { [weak delegate] in
                    delegate?.connectionInterfaceDidConnect()
                }
                self.receiveNext()
            case let .waiting(error):
                // The handshake was refused (404 for a wrong key) or there is no route.
                let described = Impl.describe(error)
                TGeshkaGateway.shared.reportError(described.kind, technical: "waiting: " + described.technical)
                self.cancelWithError(error: error, reason: "waiting")
            case let .failed(error):
                let described = Impl.describe(error)
                TGeshkaGateway.shared.reportError(described.kind, technical: "failed: " + described.technical)
                self.cancelWithError(error: error, reason: "connection failed")
            default:
                break
            }
        }

        // if-case chains, not switches: NWError and CloseCode may gain cases in a new SDK, and both a missing
        // and an unreachable default are warnings, which are errors here.
        private static func describe(_ error: NWError) -> (kind: TGeshkaGatewayErrorKind, technical: String) {
            if case let .posix(code) = error {
                return (code == .ECONNREFUSED ? .refused : .network, "POSIX \(code.rawValue): \(error.debugDescription)")
            }
            if case let .tls(status) = error {
                return (.tls, "TLS OSStatus \(status): \(error.debugDescription)")
            }
            if case let .dns(code) = error {
                return (.dns, "DNS \(code): \(error.debugDescription)")
            }
            return (.other, error.debugDescription)
        }

        /// nil: a normal close (the DC or a gateway restart), not an error.
        private static func closeErrorCode(_ code: NWProtocolWebSocket.CloseCode) -> Int? {
            if case let .protocolCode(value) = code {
                if value == .normalClosure || value == .goingAway {
                    return nil
                }
                return Int(value.rawValue)
            }
            if case let .privateCode(value) = code {
                return Int(value)
            }
            if case let .applicationCode(value) = code {
                return Int(value)
            }
            return -1
        }

        private func receiveNext() {
            guard let connection = self.connection else {
                return
            }
            connection.receiveMessage(completion: { [weak self] data, context, _, error in
                guard let self = self, self.connection != nil else {
                    return
                }
                if let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                    switch metadata.opcode {
                    case .close:
                        Logger.shared.log("GwWs", "\(self.logId) close from gateway: \(metadata.closeCode)")
                        if let code = Impl.closeErrorCode(metadata.closeCode) {
                            TGeshkaGateway.shared.reportError(.closed(code), technical: "WebSocket close \(code) from the gateway (\(metadata.closeCode))")
                        }
                        self.cancelWithError(error: nil, reason: "gateway close")
                        return
                    case .binary:
                        if let data = data, !data.isEmpty {
                            self.received(data)
                        }
                    case .text:
                        self.cancelWithError(error: nil, reason: "unexpected text message")
                        return
                    default:
                        break
                    }
                } else if let data = data, !data.isEmpty {
                    self.received(data)
                }
                if let error = error {
                    let described = Impl.describe(error)
                    TGeshkaGateway.shared.reportError(described.kind, technical: "receive: " + described.technical)
                    self.cancelWithError(error: error, reason: "receive failed")
                    return
                }
                self.receiveNext()
            })
        }

        private func received(_ data: Data) {
            TGeshkaGateway.shared.addTraffic(incoming: data.count, outgoing: 0)
            self.networkUsageManager?.addIncomingBytes(UInt(data.count), interface: self.currentInterfaceIsWifi ? MTNetworkUsageManagerInterfaceOther : MTNetworkUsageManagerInterfaceWWAN)
            self.inbound.append(data)
            self.processReads()
        }

        func write(data: Data) {
            guard let connection = self.connection else {
                return
            }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ [weak self] error in
                guard let self = self, let error = error else {
                    return
                }
                self.cancelWithError(error: error, reason: "send failed")
            }))
            TGeshkaGateway.shared.addTraffic(incoming: 0, outgoing: data.count)
            self.networkUsageManager?.addOutgoingBytes(UInt(data.count), interface: self.currentInterfaceIsWifi ? MTNetworkUsageManagerInterfaceOther : MTNetworkUsageManagerInterfaceWWAN)
        }

        func read(length: Int, tag: Int) {
            self.readRequests.append(ReadRequest(length: length, tag: tag))
            self.processReads()
        }

        // Serves MtProtoKit's exact-length reads from the bytes of the WebSocket
        // messages; message boundaries carry no meaning in the gateway stream.
        private func processReads() {
            while true {
                if self.currentReadRequest == nil {
                    if self.readRequests.isEmpty {
                        return
                    }
                    self.currentReadRequest = ExecutingReadRequest(request: self.readRequests.removeFirst())
                }
                guard let current = self.currentReadRequest else {
                    return
                }
                let needed = current.request.length - current.readyLength
                if needed > 0 {
                    if self.inbound.isEmpty {
                        return
                    }
                    let count = min(needed, self.inbound.count)
                    let chunk = self.inbound.prefix(count)
                    current.data.replaceSubrange(current.readyLength ..< current.readyLength + count, with: chunk)
                    current.readyLength += count
                    self.inbound.removeFirst(count)
                    let tag = current.request.tag
                    let delegate = self.delegate
                    self.delegateQueue.async { [weak delegate] in
                        delegate?.connectionInterfaceDidReadPartialData(ofLength: UInt(count), tag: tag)
                    }
                }
                if current.readyLength == current.request.length {
                    self.currentReadRequest = nil
                    let delegate = self.delegate
                    let networkType: Int32 = self.currentInterfaceIsWifi ? 0 : 1
                    self.delegateQueue.async { [weak delegate] in
                        delegate?.connectionInterfaceDidRead(current.data, withTag: current.request.tag, networkType: networkType)
                    }
                }
            }
        }

        private func cancelWithError(error: Error?, reason: String) {
            if let connectTimeoutTimer = self.connectTimeoutTimer {
                self.connectTimeoutTimer = nil
                connectTimeoutTimer.invalidate()
            }
            if let registrationId = self.registrationId {
                self.registrationId = nil
                TGeshkaGateway.shared.unregisterConnection(registrationId)
            }
            if self.countedAsOpen {
                self.countedAsOpen = false
                TGeshkaGateway.shared.connectionClosed()
            }
            if !self.reportedDisconnection {
                self.reportedDisconnection = true
                Logger.shared.log("GwWs", "\(self.logId) disconnected: \(reason)")
                let delegate = self.delegate
                self.delegateQueue.async { [weak delegate] in
                    delegate?.connectionInterfaceDidDisconnectWithError(error)
                }
            }
            if let connection = self.connection {
                self.connection = nil
                connection.cancel()
            }
        }

        func disconnect() {
            self.cancelWithError(error: nil, reason: "disconnect requested")
        }

        func resetDelegate() {
            self.delegate = nil
        }
    }

    private static let sharedQueue = Queue(name: "GatewayTcpConnectionInterface")

    private let impl: QueueLocalObject<Impl>

    init(delegate: MTTcpConnectionInterfaceDelegate, delegateQueue: DispatchQueue) {
        let queue = GatewayTcpConnectionInterface.sharedQueue
        self.impl = QueueLocalObject(queue: queue, generate: {
            return Impl(queue: queue, delegate: delegate, delegateQueue: delegateQueue)
        })
    }

    func setGetLogPrefix(_ getLogPrefix: (() -> String)?) {
        self.impl.with { impl in
            impl.setGetLogPrefix(getLogPrefix)
        }
    }

    func setUsageCalculationInfo(_ usageCalculationInfo: MTNetworkUsageCalculationInfo?) {
        self.impl.with { impl in
            impl.setUsageCalculationInfo(usageCalculationInfo)
        }
    }

    func connect(toHost inHost: String, onPort port: UInt16, viaInterface inInterface: String?, withTimeout timeout: TimeInterval, error errPtr: NSErrorPointer) -> Bool {
        self.impl.with { impl in
            impl.connect(host: inHost, port: port, timeout: timeout)
        }
        return true
    }

    func write(_ data: Data) {
        self.impl.with { impl in
            impl.write(data: data)
        }
    }

    func readData(toLength length: UInt, withTimeout timeout: TimeInterval, tag: Int) {
        self.impl.with { impl in
            impl.read(length: Int(length), tag: tag)
        }
    }

    func disconnect() {
        self.impl.with { impl in
            impl.disconnect()
        }
    }

    func resetDelegate() {
        self.impl.with { impl in
            impl.resetDelegate()
        }
    }
}
