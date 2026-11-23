import Foundation
import SwiftSignalKit
import Postbox
internal import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    // TGeshka: APNs pushes come through the Web Push relay (token_type 10).
    if case .aps = type {
        guard let endpoint = TGeshkaWebPush.cachedEndpoint, let webToken = TGeshkaWebPush.subscriptionToken(accountId: account.id.int64, endpoint: endpoint) else {
            return .complete()
        }
        return account.network.request(Api.functions.account.unregisterDevice(tokenType: 10, token: webToken, otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> retryRequest
        |> ignoreValues
    }
    let mappedType: Int32
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: hexString(token), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<Bool, NoError> {
    // TGeshka: Telegram has no APNs certificate for this app, so the APNs token goes to
    // our relay and Telegram gets a Web Push subscription pointing there (token_type 10).
    if case .voip = type {
        // TGeshka: Telegram cannot send VoIP pushes to this app either, and a VoIP token of the
        // session may take the place of the Web Push subscription, so it is removed instead.
        return account.network.request(Api.functions.account.unregisterDevice(tokenType: 9, token: hexString(token), otherUids: []))
        |> map { _ -> Bool in
            TGeshkaWebPush.report(apnsToken: nil, stage: "voip_unregister", result: "ok")
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            let code: String = error.errorDescription ?? "unknown"
            TGeshkaWebPush.report(apnsToken: nil, stage: "voip_unregister", result: code)
            return .single(true)
        }
    }
    if case .aps = type {
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        let accountId = account.id.int64
        // A plain APNs token (token_type 1) left from an earlier build goes nowhere: Telegram has no
        // certificate for this app. It is removed so that only the Web Push subscription stays.
        let dropLegacy: Signal<Bool, NoError> = account.network.request(Api.functions.account.unregisterDevice(tokenType: 1, token: hexString(token), otherUids: []))
        |> map { _ -> Bool in
            return true
        }
        |> `catch` { _ -> Signal<Bool, NoError> in
            return .single(false)
        }
        return dropLegacy
        |> mapToSignal { _ -> Signal<String?, NoError> in
            return TGeshkaWebPush.relayEndpoint(apnsToken: token, sandbox: sandbox)
        }
        |> mapToSignal { endpoint -> Signal<Bool, NoError> in
            guard let endpoint = endpoint, let webToken = TGeshkaWebPush.subscriptionToken(accountId: accountId, endpoint: endpoint) else {
                Logger.shared.log("TGeshkaPush", "no relay endpoint, push notifications are off")
                return .single(true)
            }
            return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: 10, token: webToken, appSandbox: .boolFalse, secret: Buffer(data: Data()), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
            |> map { _ -> Bool in
                Logger.shared.log("TGeshkaPush", "web push subscription registered")
                TGeshkaWebPush.report(apnsToken: token, stage: "register_device", result: "ok")
                return true
            }
            |> `catch` { error -> Signal<Bool, NoError> in
                let code: String = error.errorDescription ?? "unknown"
                Logger.shared.log("TGeshkaPush", "registerDevice failed: \(code)")
                TGeshkaWebPush.report(apnsToken: token, stage: "register_device", result: code)
                return .single(true)
            }
        }
    }
    return masterNotificationsKey(account: account, ignoreDisabled: false)
    |> mapToSignal { masterKey -> Signal<Bool, NoError> in
        let mappedType: Int32
        var keyData = Data()
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = masterKey.data
                }
            case .voip:
                mappedType = 9
                keyData = masterKey.data
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: hexString(token), appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { _ -> Bool in
            return true
        }
        |> `catch` { error -> Signal<Bool, NoError> in
            if error.errorDescription == "TOKEN_WAS_INVALIDATED" {
                return .single(false)
            } else {
                return .single(true)
            }
        }
    }
}
