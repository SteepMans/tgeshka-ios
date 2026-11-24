import Foundation
import CryptoKit
import SwiftSignalKit

// TGeshka push notifications.
//
// Telegram delivers APNs pushes only to apps whose certificate it holds, so TGeshka
// registers a Web Push subscription instead (account.registerDevice token_type 10).
// Telegram encrypts every push to the device's P-256 key (RFC 8291) and posts it to
// the endpoint of our relay; the relay cannot read it and forwards the ciphertext to
// APNs with our own key. The notification service extension decrypts it here with
// the private key that never leaves the app group container.

public struct TGeshkaWebPushDecrypted {
    public let accountId: Int64
    public let payload: [String: Any]
}

public final class TGeshkaWebPush {
    private struct StoredKey: Codable {
        var privateKey: String
        var auth: String
    }

    private struct Store: Codable {
        var keys: [String: StoredKey]
        var endpoint: String?
        var endpointApnsToken: String?
    }

    private static let lock = NSLock()

    private static func storeUrl() -> URL? {
        return TGeshkaGateway.sharedContainerUrl()?.appendingPathComponent("tgeshka-webpush.json")
    }

    private static func load() -> Store {
        guard let url = storeUrl(), let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(Store.self, from: data) else {
            return Store(keys: [:], endpoint: nil, endpointApnsToken: nil)
        }
        return store
    }

    private static func save(_ store: Store) {
        guard let url = storeUrl(), let data = try? JSONEncoder().encode(store) else {
            return
        }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func base64Url(_ data: Data) -> String {
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func dataFromBase64Url(_ string: String) -> Data? {
        var value = string.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 {
            value.append("=")
        }
        return Data(base64Encoded: value)
    }

    /// Key pair and auth secret of one account, created on first use.
    private static func keys(accountId: Int64) -> (P256.KeyAgreement.PrivateKey, Data)? {
        lock.lock()
        defer { lock.unlock() }
        var store = load()
        if let stored = store.keys["\(accountId)"], let raw = Data(base64Encoded: stored.privateKey), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw), let auth = Data(base64Encoded: stored.auth) {
            return (key, auth)
        }
        let key = P256.KeyAgreement.PrivateKey()
        let auth = SymmetricKey(size: SymmetricKeySize(bitCount: 128)).withUnsafeBytes { Data($0) }
        store.keys["\(accountId)"] = StoredKey(privateKey: key.rawRepresentation.base64EncodedString(), auth: auth.base64EncodedString())
        save(store)
        return (key, auth)
    }

    /// The token for account.registerDevice(token_type: 10): {"endpoint", "keys": {"p256dh", "auth"}}.
    /// No "vapid": with it Telegram refuses the registration with APP_PUSH_APIKEY_MISSING (it needs
    /// the app's VAPID key, which only Telegram Web has); without it pushes come as "aesgcm".
    static func subscriptionToken(accountId: Int64, endpoint: String) -> String? {
        guard case let (key, auth)? = keys(accountId: accountId) else {
            return nil
        }
        let object: [String: Any] = [
            "endpoint": endpoint,
            "keys": [
                "p256dh": base64Url(key.publicKey.x963Representation),
                "auth": base64Url(auth)
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static var cachedEndpoint: String? {
        lock.lock()
        defer { lock.unlock() }
        return load().endpoint
    }

    /// Registers the APNs token with the relay and returns the Web Push endpoint
    /// Telegram should post to. Repeated calls with the same token reuse the endpoint.
    static func relayEndpoint(apnsToken: Data, sandbox: Bool) -> Signal<String?, NoError> {
        let tokenHex = apnsToken.map { String(format: "%02x", $0) }.joined()
        lock.lock()
        let store = load()
        lock.unlock()
        let gateway = TGeshkaGateway.shared
        let settings = gateway.settings
        guard !settings.token.isEmpty, var components = URLComponents(string: gateway.effectiveUrl) else {
            return .single(store.endpointApnsToken == tokenHex ? store.endpoint : nil)
        }
        components.scheme = "https"
        components.path = "/v1/push/register"
        components.query = nil
        guard let url = components.url else {
            return .single(nil)
        }
        return Signal { subscriber in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
            request.httpMethod = "POST"
            request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
            request.setValue(TGeshkaGateway.clientHeader, forHTTPHeaderField: "X-TGeshka-Client")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "apns_token": tokenHex,
                "sandbox": sandbox,
                "topic": Bundle.main.bundleIdentifier ?? ""
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            let session = URLSession(configuration: configuration)
            let task = session.dataTask(with: request, completionHandler: { data, response, _ in
                var endpoint: String?
                if let response = response as? HTTPURLResponse, response.statusCode == 200, let data = data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    endpoint = json["endpoint"] as? String
                }
                if let endpoint = endpoint {
                    TGeshkaWebPush.lock.lock()
                    var updated = TGeshkaWebPush.load()
                    updated.endpoint = endpoint
                    updated.endpointApnsToken = tokenHex
                    TGeshkaWebPush.save(updated)
                    TGeshkaWebPush.lock.unlock()
                    Logger.shared.log("TGeshkaPush", "relay endpoint registered")
                } else {
                    Logger.shared.log("TGeshkaPush", "relay registration failed: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    if store.endpointApnsToken == tokenHex {
                        endpoint = store.endpoint
                    }
                }
                subscriber.putNext(endpoint)
                subscriber.putCompletion()
            })
            task.resume()
            return ActionDisposable {
                task.cancel()
                session.finishTasksAndInvalidate()
            }
        }
    }

    /// Tells the relay how a step of the subscription went (Telegram's answer to
    /// registerDevice and the like): the relay logs it next to the deliveries, so a push
    /// that never comes can be told from a subscription Telegram refused. Fire and forget.
    static func report(apnsToken: Data?, stage: String, result: String) {
        let gateway = TGeshkaGateway.shared
        let settings = gateway.settings
        guard !settings.token.isEmpty, var components = URLComponents(string: gateway.effectiveUrl) else {
            return
        }
        components.scheme = "https"
        components.path = "/v1/push/report"
        components.query = nil
        guard let url = components.url else {
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20.0)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.token)", forHTTPHeaderField: "Authorization")
        request.setValue(TGeshkaGateway.clientHeader, forHTTPHeaderField: "X-TGeshka-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["stage": stage, "result": result]
        if let apnsToken = apnsToken {
            body["apns_token"] = apnsToken.map { String(format: "%02x", $0) }.joined()
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request, completionHandler: { _, _, _ in }).resume()
        session.finishTasksAndInvalidate()
    }

    // MARK: Decryption

    private static func hkdf(salt: Data, ikm: Data, info: Data, length: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info, outputByteCount: length)
        return key.withUnsafeBytes { Data($0) }
    }

    private static func sharedSecret(_ key: P256.KeyAgreement.PrivateKey, _ publicKey: Data) -> Data? {
        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: publicKey), let secret = try? key.sharedSecretFromKeyAgreement(with: peer) else {
            return nil
        }
        return secret.withUnsafeBytes { Data($0) }
    }

    private static func open(cek: Data, nonce: Data, sealed: Data) -> Data? {
        guard sealed.count > 16, let nonceValue = try? AES.GCM.Nonce(data: nonce) else {
            return nil
        }
        let ciphertext = sealed.prefix(sealed.count - 16)
        let tag = sealed.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: nonceValue, ciphertext: ciphertext, tag: tag) else {
            return nil
        }
        return try? AES.GCM.open(box, using: SymmetricKey(data: cek))
    }

    /// RFC 8291 / RFC 8188, single record.
    static func decryptAes128gcm(body: Data, key: P256.KeyAgreement.PrivateKey, auth: Data) -> Data? {
        let bytes = [UInt8](body)
        guard bytes.count > 21 else {
            return nil
        }
        let salt = Data(bytes[0 ..< 16])
        let idLength = Int(bytes[20])
        guard bytes.count > 21 + idLength, idLength == 65 else {
            return nil
        }
        let serverPublic = Data(bytes[21 ..< 21 + idLength])
        let sealed = Data(bytes[(21 + idLength)...])
        guard let ecdh = sharedSecret(key, serverPublic) else {
            return nil
        }
        var keyInfo = Data("WebPush: info".utf8)
        keyInfo.append(0)
        keyInfo.append(key.publicKey.x963Representation)
        keyInfo.append(serverPublic)
        let ikm = hkdf(salt: auth, ikm: ecdh, info: keyInfo, length: 32)
        var cekInfo = Data("Content-Encoding: aes128gcm".utf8)
        cekInfo.append(0)
        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(0)
        let cek = hkdf(salt: salt, ikm: ikm, info: cekInfo, length: 16)
        let nonce = hkdf(salt: salt, ikm: ikm, info: nonceInfo, length: 12)
        guard var plain = open(cek: cek, nonce: nonce, sealed: sealed) else {
            return nil
        }
        while let last = plain.last, last == 0 {
            plain.removeLast()
        }
        guard let delimiter = plain.last, delimiter == 2 || delimiter == 1 else {
            return nil
        }
        plain.removeLast()
        return plain
    }

    /// Legacy "aesgcm" encoding (draft-ietf-webpush-encryption-04): salt and the
    /// server key come in the Encryption / Crypto-Key headers.
    static func decryptAesgcm(body: Data, salt: Data, serverPublic: Data, key: P256.KeyAgreement.PrivateKey, auth: Data) -> Data? {
        guard let ecdh = sharedSecret(key, serverPublic) else {
            return nil
        }
        var authInfo = Data("Content-Encoding: auth".utf8)
        authInfo.append(0)
        let prk = hkdf(salt: auth, ikm: ecdh, info: authInfo, length: 32)
        let clientPublic = key.publicKey.x963Representation
        var context = Data("P-256".utf8)
        context.append(0)
        context.append(UInt8(clientPublic.count >> 8))
        context.append(UInt8(clientPublic.count & 0xff))
        context.append(clientPublic)
        context.append(UInt8(serverPublic.count >> 8))
        context.append(UInt8(serverPublic.count & 0xff))
        context.append(serverPublic)
        var cekInfo = Data("Content-Encoding: aesgcm".utf8)
        cekInfo.append(0)
        cekInfo.append(context)
        var nonceInfo = Data("Content-Encoding: nonce".utf8)
        nonceInfo.append(0)
        nonceInfo.append(context)
        let cek = hkdf(salt: salt, ikm: prk, info: cekInfo, length: 16)
        let nonce = hkdf(salt: salt, ikm: prk, info: nonceInfo, length: 12)
        guard let plain = open(cek: cek, nonce: nonce, sealed: body), plain.count >= 2 else {
            return nil
        }
        let padding = Int(plain[plain.startIndex]) << 8 | Int(plain[plain.startIndex + 1])
        guard plain.count >= 2 + padding else {
            return nil
        }
        return plain.subdata(in: (plain.startIndex + 2 + padding) ..< plain.endIndex)
    }

    private static func headerParameter(_ header: String, _ name: String) -> String? {
        for part in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == name {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
        }
        return nil
    }

    /// Decrypts the relay's APNs payload: "wp" body (base64), "wpe" content
    /// encoding, "wps" Encryption header, "wpk" Crypto-Key header. Tries every
    /// account's key; the one that opens the record names the account.
    public static func decrypt(userInfo: [AnyHashable: Any]) -> TGeshkaWebPushDecrypted? {
        guard let bodyString = userInfo["wp"] as? String, let body = dataFromBase64Url(bodyString) else {
            return nil
        }
        let encoding = (userInfo["wpe"] as? String ?? "aes128gcm").lowercased()
        var salt: Data?
        var serverPublic: Data?
        if encoding == "aesgcm" {
            salt = (userInfo["wps"] as? String).flatMap { headerParameter($0, "salt") }.flatMap(dataFromBase64Url)
            serverPublic = (userInfo["wpk"] as? String).flatMap { headerParameter($0, "dh") }.flatMap(dataFromBase64Url)
        }
        lock.lock()
        let store = load()
        lock.unlock()
        for (accountKey, stored) in store.keys {
            guard let accountId = Int64(accountKey), let raw = Data(base64Encoded: stored.privateKey), let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: raw), let auth = Data(base64Encoded: stored.auth) else {
                continue
            }
            let plain: Data?
            if encoding == "aesgcm" {
                if let salt = salt, let serverPublic = serverPublic {
                    plain = decryptAesgcm(body: body, salt: salt, serverPublic: serverPublic, key: key, auth: auth)
                } else {
                    plain = nil
                }
            } else {
                plain = decryptAes128gcm(body: body, key: key, auth: auth)
            }
            if let plain = plain {
                guard let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else {
                    report(apnsToken: nil, stage: "nse", result: "not_json enc=\(encoding) bytes=\(plain.count)")
                    return nil
                }
                // Only the names of the fields and the notification type go to the relay, never the values.
                let inner = (json["data"] as? [String: Any]) ?? json
                let locKey = inner["loc_key"] as? String ?? "none"
                let keys = inner.keys.sorted().joined(separator: ",")
                report(apnsToken: nil, stage: "nse", result: "ok enc=\(encoding) loc=\(locKey) keys=\(keys)")
                return TGeshkaWebPushDecrypted(accountId: accountId, payload: apnsShapedPayload(json))
            }
        }
        report(apnsToken: nil, stage: "nse", result: "decrypt_failed enc=\(encoding) salt=\(salt != nil) dh=\(serverPublic != nil) accounts=\(store.keys.count) bytes=\(body.count)")
        return nil
    }

    /// Web Push data comes as {"loc_key", "loc_args", "custom": {...}, "title",
    /// "description", ...}; the notification service reads the APNs shape
    /// ({"aps": {"alert": ...}, "loc-key", "msg_id", "from_id", ...}).
    static func apnsShapedPayload(_ object: [String: Any]) -> [String: Any] {
        // The API docs show the notification wrapped as {"data": {...}}; accept both shapes.
        let json: [String: Any]
        if object["loc_key"] == nil, let data = object["data"] as? [String: Any] {
            json = data
        } else {
            json = object
        }
        var result: [String: Any] = [:]
        for (key, value) in json where key != "custom" {
            result[key] = value
        }
        if let custom = json["custom"] as? [String: Any] {
            for (key, value) in custom {
                if let number = value as? NSNumber {
                    result[key] = number.stringValue
                } else {
                    result[key] = value
                }
            }
        }
        if let locKey = json["loc_key"] as? String {
            result["loc-key"] = locKey
        }
        if let locArgs = json["loc_args"] {
            result["loc-args"] = locArgs
        }
        if result["aps"] == nil {
            var alert: [String: Any] = [:]
            let args = json["loc_args"] as? [String] ?? []
            if let title = json["title"] as? String, !title.isEmpty {
                alert["title"] = title
            } else if let first = args.first {
                alert["title"] = first
            }
            if let description = json["description"] as? String, !description.isEmpty {
                alert["body"] = description
            } else if args.count > 1 {
                alert["body"] = args.dropFirst().joined(separator: ": ")
            } else {
                alert["body"] = "Новое сообщение"
            }
            var aps: [String: Any] = ["alert": alert, "mutable-content": 1]
            if json["silent"] as? String != "1" {
                aps["sound"] = "default"
            }
            if let badge = json["badge"] as? String, let value = Int(badge) {
                aps["badge"] = value
            }
            result["aps"] = aps
        }
        return result
    }
}
