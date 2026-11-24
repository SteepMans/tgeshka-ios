import Foundation
import Postbox
import SwiftSignalKit

// TGeshka members (SteepMans/api-gateway docs/tg-protocol-v1.md, "Участники TGeshka").
// The app tells the gateway which Telegram accounts use it (POST /v1/members/me) and
// gets the ids of other TGeshka users (GET /v1/members, ETag) to show the lavender
// TGeshka badge next to their names. The list is cached in the app group container and
// refreshed at start and every hour while the app runs.

private struct TGeshkaMembersCache: Codable {
    var ids: [Int64]
    var version: String
}

public final class TGeshkaMembers {
    public static let shared = TGeshkaMembers()

    private static let visibleKey = "tgeshka.members.visible"
    private static let hour: Double = 60.0 * 60.0

    private let queue = Queue(name: "org.telegram.tgeshka.members")
    private let lock = NSLock()
    private var ids: Set<Int64> = Set()
    private var version: String = ""
    private var accounts: Set<Int64> = Set()
    private var reported: Set<Int64> = Set()
    private var lastFetch: Double = 0.0
    private var lastReport: Double = 0.0
    private var busy = false
    private var timer: SwiftSignalKit.Timer?
    private let updatedPromise = ValuePromise<Int>(0, ignoreRepeated: false)
    private var updateCounter = 0

    private init() {
        if let cache = TGeshkaMembers.loadCache() {
            self.ids = Set(cache.ids)
            self.version = cache.version
        }
    }

    /// Fires when the member list or the visibility switch changes.
    public var updated: Signal<Int, NoError> {
        return self.updatedPromise.get()
    }

    /// «Показывать, что я пользуюсь TGeshka», on by default.
    public var isVisible: Bool {
        if UserDefaults.standard.object(forKey: TGeshkaMembers.visibleKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: TGeshkaMembers.visibleKey)
    }

    public func setVisible(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: TGeshkaMembers.visibleKey)
        self.lock.lock()
        self.reported.removeAll()
        self.lock.unlock()
        self.notifyUpdated()
        self.queue.async {
            self.check(force: true)
        }
    }

    /// True for TGeshka users from the gateway list and for the own accounts while the switch is on.
    public func isMember(_ userId: Int64) -> Bool {
        if userId <= 0 {
            return false
        }
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.accounts.contains(userId) {
            return self.isVisible
        }
        return self.ids.contains(userId)
    }

    public func isMember(peerId: PeerId) -> Bool {
        guard peerId.namespace == Namespaces.Peer.CloudUser else {
            return false
        }
        return self.isMember(peerId.id._internalGetInt64Value())
    }

    public func isMember(peer: EnginePeer?) -> Bool {
        guard let peer = peer, case let .user(user) = peer, user.botInfo == nil, !user.isDeleted else {
            return false
        }
        return self.isMember(peerId: user.id)
    }

    /// Called for every account of the main app process (not for extensions).
    func addAccount(_ userId: Int64) {
        if Bundle.main.bundlePath.hasSuffix(".appex") || userId <= 0 {
            return
        }
        self.lock.lock()
        self.accounts.insert(userId)
        self.lock.unlock()
        self.queue.async {
            if self.timer == nil {
                let timer = SwiftSignalKit.Timer(timeout: 60.0, repeat: true, completion: { [weak self] in
                    self?.check(force: false)
                }, queue: self.queue)
                self.timer = timer
                timer.start()
            }
            self.check(force: false)
        }
    }

    private func notifyUpdated() {
        self.lock.lock()
        self.updateCounter += 1
        let value = self.updateCounter
        self.lock.unlock()
        self.updatedPromise.set(value)
    }

    // MARK: Network (on self.queue)

    private func check(force: Bool) {
        let settings = TGeshkaGateway.shared.settings
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let gatewayUrl = TGeshkaGateway.shared.effectiveUrl
        if self.busy || token.isEmpty || gatewayUrl.isEmpty {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        self.lock.lock()
        let all = force || now - self.lastReport > TGeshkaMembers.hour
        let toReport = self.accounts.filter { all || !self.reported.contains($0) }
        let version = self.version
        self.lock.unlock()
        let fetch = force || !toReport.isEmpty || now - self.lastFetch > TGeshkaMembers.hour
        if !fetch {
            return
        }
        self.busy = true
        let visible = self.isVisible
        let group = DispatchGroup()
        var reportedIds: [Int64] = []
        var failed = false
        let resultLock = NSLock()
        for userId in toReport {
            group.enter()
            self.post(gatewayUrl: gatewayUrl, token: token, userId: userId, visible: visible, completion: { ok in
                resultLock.lock()
                if ok {
                    reportedIds.append(userId)
                } else {
                    failed = true
                }
                resultLock.unlock()
                group.leave()
            })
        }
        group.notify(queue: self.queue.queue, execute: {
            self.lock.lock()
            for userId in reportedIds {
                self.reported.insert(userId)
            }
            if !failed && !toReport.isEmpty {
                self.lastReport = CFAbsoluteTimeGetCurrent()
            }
            self.lock.unlock()
            self.fetchList(gatewayUrl: gatewayUrl, token: token, version: version, completion: { ok in
                self.queue.async {
                    if ok {
                        self.lastFetch = CFAbsoluteTimeGetCurrent()
                    }
                    self.busy = false
                }
            })
        })
    }

    private static func endpoint(gatewayUrl: String, path: String) -> URL? {
        guard var components = URLComponents(string: gatewayUrl) else {
            return nil
        }
        components.scheme = "https"
        components.path = path
        components.query = nil
        return components.url
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private func post(gatewayUrl: String, token: String, userId: Int64, visible: Bool, completion: @escaping (Bool) -> Void) {
        guard let url = TGeshkaMembers.endpoint(gatewayUrl: gatewayUrl, path: "/v1/members/me"), let body = try? JSONSerialization.data(withJSONObject: ["user_id": NSNumber(value: userId), "visible": visible]) else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(TGeshkaGateway.clientHeader, forHTTPHeaderField: "X-TGeshka-Client")
        let session = TGeshkaMembers.makeSession()
        let task = session.dataTask(with: request, completionHandler: { _, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 429: the key already claims its limit of accounts, repeating every minute would not help.
            completion(code == 200 || code == 400 || code == 429)
        })
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private func fetchList(gatewayUrl: String, token: String, version: String, completion: @escaping (Bool) -> Void) {
        guard let url = TGeshkaMembers.endpoint(gatewayUrl: gatewayUrl, path: "/v1/members") else {
            completion(false)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15.0)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(TGeshkaGateway.clientHeader, forHTTPHeaderField: "X-TGeshka-Client")
        if !version.isEmpty {
            request.setValue("\"\(version)\"", forHTTPHeaderField: "If-None-Match")
        }
        let session = TGeshkaMembers.makeSession()
        let task = session.dataTask(with: request, completionHandler: { [weak self] data, response, _ in
            guard let self = self, let response = response as? HTTPURLResponse else {
                completion(false)
                return
            }
            if response.statusCode == 304 {
                completion(true)
                return
            }
            guard response.statusCode == 200, let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                completion(false)
                return
            }
            var list: [Int64] = []
            if let values = json["user_ids"] as? [Any] {
                for value in values {
                    if let number = value as? NSNumber, number.int64Value > 0 {
                        list.append(number.int64Value)
                    }
                }
            }
            let newVersion = json["version"] as? String ?? ""
            let newIds = Set(list)
            self.lock.lock()
            let changed = newIds != self.ids
            self.ids = newIds
            self.version = newVersion
            self.lock.unlock()
            TGeshkaMembers.storeCache(TGeshkaMembersCache(ids: list, version: newVersion))
            if changed {
                self.notifyUpdated()
            }
            completion(true)
        })
        task.resume()
        session.finishTasksAndInvalidate()
    }

    // MARK: Cache

    private static func cacheUrl() -> URL? {
        if let container = TGeshkaGateway.sharedContainerUrl() {
            return container.appendingPathComponent("tgeshka-members.json")
        }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("tgeshka-members.json")
    }

    private static func loadCache() -> TGeshkaMembersCache? {
        guard let url = cacheUrl(), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(TGeshkaMembersCache.self, from: data)
    }

    private static func storeCache(_ cache: TGeshkaMembersCache) {
        guard let url = cacheUrl(), let data = try? JSONEncoder().encode(cache) else {
            return
        }
        try? data.write(to: url, options: [.atomic])
    }
}
