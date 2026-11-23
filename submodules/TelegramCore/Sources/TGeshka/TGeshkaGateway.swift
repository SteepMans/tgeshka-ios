import Foundation
import SwiftSignalKit

// TGeshka: every MTProto connection goes through the gateway (WebSocket, see
// SteepMans/api-gateway docs/tg-protocol-v1.md). Settings live in the app group
// container, so the app and its extensions (notification service, share, widget)
// use the same gateway address and access key.

public struct TGeshkaGatewaySettings: Codable, Equatable {
    public var url: String
    public var token: String

    public init(url: String, token: String) {
        self.url = url
        self.token = token
    }
}

public struct TGeshkaGatewayStats: Equatable {
    public var activeConnections: Int
    public var openedConnections: Int
    public var bytesIn: Int64
    public var bytesOut: Int64
    public var lastHandshakeMs: Int?
    public var lastError: String?
    public var lastErrorDate: Date?
    public var lastConnectedDate: Date?
}

public struct TGeshkaGatewayInfo: Equatable {
    public var description: String
    public var maxConnections: Int
    public var activeConnections: Int
    public var status: String
    public var rttMs: Int
}

public enum TGeshkaGatewayInfoError: Equatable {
    case noKey
    case badUrl
    case rejected
    case network(String)
}

public final class TGeshkaGateway {
    public static let shared = TGeshkaGateway()

    public static let linkScheme = "tgeshka"

    private let lock = NSLock()
    private var currentSettings: TGeshkaGatewaySettings
    private var stats = TGeshkaGatewayStats(activeConnections: 0, openedConnections: 0, bytesIn: 0, bytesOut: 0, lastHandshakeMs: nil, lastError: nil, lastErrorDate: nil, lastConnectedDate: nil)
    private var liveConnections: [Int: () -> Void] = [:]
    private var nextConnectionId: Int = 0
    private let settingsPromise: ValuePromise<TGeshkaGatewaySettings>

    private init() {
        let loaded = TGeshkaGateway.loadSettings() ?? TGeshkaGatewaySettings(url: "", token: "")
        self.currentSettings = loaded
        self.settingsPromise = ValuePromise(loaded, ignoreRepeated: true)
    }

    // MARK: Settings

    public var settings: TGeshkaGatewaySettings {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.currentSettings
    }

    public var settingsSignal: Signal<TGeshkaGatewaySettings, NoError> {
        return self.settingsPromise.get()
    }

    public static var defaultUrl: String {
        return TGeshkaBuildDefaults.gatewayUrl
    }

    public var effectiveUrl: String {
        let value = self.settings.url.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? TGeshkaGateway.defaultUrl : value
    }

    public var hasKey: Bool {
        return !self.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static var clientHeader: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "ios/\(version)"
    }

    public static func isValidKey(_ token: String) -> Bool {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("tc_"), value.count >= 20 else {
            return false
        }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
    }

    public static func isValidUrl(_ url: String) -> Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = parsed.scheme?.lowercased(), let host = parsed.host, !host.isEmpty else {
            return false
        }
        return scheme == "wss"
    }

    /// Saves the settings for the app and its extensions and drops every live
    /// connection, so MtProtoKit reconnects through the new gateway.
    public func update(_ settings: TGeshkaGatewaySettings) {
        let cleaned = TGeshkaGatewaySettings(url: settings.url.trimmingCharacters(in: .whitespacesAndNewlines), token: settings.token.trimmingCharacters(in: .whitespacesAndNewlines))
        self.lock.lock()
        let changed = cleaned != self.currentSettings
        self.currentSettings = cleaned
        self.lock.unlock()
        TGeshkaGateway.storeSettings(cleaned)
        self.settingsPromise.set(cleaned)
        if changed {
            self.reconnectAll()
        }
    }

    /// Re-reads the shared file: the app may have changed the key while an
    /// extension process was alive.
    public func reloadFromDisk() {
        guard let loaded = TGeshkaGateway.loadSettings() else {
            return
        }
        self.lock.lock()
        let changed = loaded != self.currentSettings
        self.currentSettings = loaded
        self.lock.unlock()
        if changed {
            self.settingsPromise.set(loaded)
            self.reconnectAll()
        }
    }

    /// `tgeshka://gateway?url=wss://...&token=tc_...` (url is optional).
    public static func parseLink(_ url: URL) -> TGeshkaGatewaySettings? {
        guard url.scheme?.lowercased() == TGeshkaGateway.linkScheme, url.host?.lowercased() == "gateway" else {
            return nil
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var gatewayUrl = ""
        var token = ""
        for item in components.queryItems ?? [] {
            switch item.name {
            case "url":
                gatewayUrl = item.value ?? ""
            case "token", "key":
                token = item.value ?? ""
            default:
                break
            }
        }
        guard isValidKey(token) else {
            return nil
        }
        if !gatewayUrl.isEmpty && !isValidUrl(gatewayUrl) {
            return nil
        }
        return TGeshkaGatewaySettings(url: gatewayUrl, token: token)
    }

    // MARK: Connections

    public func reconnectAll() {
        self.lock.lock()
        let disconnects = Array(self.liveConnections.values)
        self.lock.unlock()
        for disconnect in disconnects {
            disconnect()
        }
    }

    func registerConnection(disconnect: @escaping () -> Void) -> Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        let id = self.nextConnectionId
        self.nextConnectionId += 1
        self.liveConnections[id] = disconnect
        return id
    }

    func unregisterConnection(_ id: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.liveConnections.removeValue(forKey: id)
    }

    func connectionOpened(handshakeMs: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.stats.activeConnections += 1
        self.stats.openedConnections += 1
        self.stats.lastHandshakeMs = handshakeMs
        self.stats.lastConnectedDate = Date()
    }

    func connectionClosed() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.stats.activeConnections = max(0, self.stats.activeConnections - 1)
    }

    func addTraffic(incoming: Int, outgoing: Int) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.stats.bytesIn += Int64(incoming)
        self.stats.bytesOut += Int64(outgoing)
    }

    func reportError(_ text: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.stats.lastError = text
        self.stats.lastErrorDate = Date()
    }

    public var currentStats: TGeshkaGatewayStats {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stats
    }

    /// Polled once a second for the status screen.
    public var statsSignal: Signal<TGeshkaGatewayStats, NoError> {
        return Signal { subscriber in
            subscriber.putNext(TGeshkaGateway.shared.currentStats)
            let timer = SwiftSignalKit.Timer(timeout: 1.0, repeat: true, completion: {
                subscriber.putNext(TGeshkaGateway.shared.currentStats)
            }, queue: Queue.mainQueue())
            timer.start()
            return ActionDisposable {
                timer.invalidate()
            }
        }
    }

    // MARK: /v1/info

    static func infoUrl(gatewayUrl: String) -> URL? {
        guard var components = URLComponents(string: gatewayUrl) else {
            return nil
        }
        components.scheme = "https"
        components.path = "/v1/info"
        components.query = nil
        return components.url
    }

    public func fetchInfo(settings: TGeshkaGatewaySettings? = nil) -> Signal<TGeshkaGatewayInfo, TGeshkaGatewayInfoError> {
        let settings = settings ?? self.settings
        let gatewayUrl = settings.url.isEmpty ? TGeshkaGateway.defaultUrl : settings.url
        let token = settings.token
        return Signal { subscriber in
            if token.isEmpty {
                subscriber.putError(.noKey)
                return EmptyDisposable
            }
            guard let url = TGeshkaGateway.infoUrl(gatewayUrl: gatewayUrl) else {
                subscriber.putError(.badUrl)
                return EmptyDisposable
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(TGeshkaGateway.clientHeader, forHTTPHeaderField: "X-TGeshka-Client")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            let start = CFAbsoluteTimeGetCurrent()
            let task = session.dataTask(with: request, completionHandler: { data, response, error in
                let rttMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
                if let error = error {
                    subscriber.putError(.network(error.localizedDescription))
                    return
                }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    subscriber.putError(.rejected)
                    return
                }
                let info = TGeshkaGatewayInfo(
                    description: json["description"] as? String ?? "",
                    maxConnections: (json["max_connections"] as? NSNumber)?.intValue ?? 0,
                    activeConnections: (json["active_connections"] as? NSNumber)?.intValue ?? 0,
                    status: json["status"] as? String ?? "",
                    rttMs: rttMs
                )
                subscriber.putNext(info)
                subscriber.putCompletion()
            })
            task.resume()
            return ActionDisposable {
                task.cancel()
                session.finishTasksAndInvalidate()
            }
        }
    }

    // MARK: Storage

    static func sharedContainerUrl() -> URL? {
        guard var bundleId = Bundle.main.bundleIdentifier else {
            return nil
        }
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            var parts = bundleId.components(separatedBy: ".")
            if parts.count > 1 {
                parts.removeLast()
            }
            bundleId = parts.joined(separator: ".")
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.\(bundleId)")
    }

    private static func settingsFileUrl() -> URL? {
        return sharedContainerUrl()?.appendingPathComponent("tgeshka-gateway.json")
    }

    private static func loadSettings() -> TGeshkaGatewaySettings? {
        guard let url = settingsFileUrl(), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(TGeshkaGatewaySettings.self, from: data)
    }

    private static func storeSettings(_ settings: TGeshkaGatewaySettings) {
        guard let url = settingsFileUrl(), let data = try? JSONEncoder().encode(settings) else {
            return
        }
        #if os(iOS)
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try? data.write(to: url, options: [.atomic])
        #endif
    }
}
