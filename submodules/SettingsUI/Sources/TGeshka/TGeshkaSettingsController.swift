import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// TGeshka settings: gateway address and access key, gateway state, about.

private final class TGeshkaSettingsArguments {
    let updateUrl: (String) -> Void
    let updateKey: (String) -> Void
    let paste: () -> Void
    let save: () -> Void
    let reconnect: () -> Void
    let openSources: () -> Void

    init(updateUrl: @escaping (String) -> Void, updateKey: @escaping (String) -> Void, paste: @escaping () -> Void, save: @escaping () -> Void, reconnect: @escaping () -> Void, openSources: @escaping () -> Void) {
        self.updateUrl = updateUrl
        self.updateKey = updateKey
        self.paste = paste
        self.save = save
        self.reconnect = reconnect
        self.openSources = openSources
    }
}

private enum TGeshkaSettingsSection: Int32 {
    case intro
    case gateway
    case state
    case about
}

private enum TGeshkaCheckState: Equatable {
    case none
    case checking
    case ok(TGeshkaGatewayInfo)
    case failed(String)
}

private struct TGeshkaSettingsState: Equatable {
    var url: String
    var key: String
    var check: TGeshkaCheckState
    var stats: TGeshkaGatewayStats
}

private enum TGeshkaSettingsEntry: ItemListNodeEntry {
    case intro(String)
    case pasteLink(String)
    case gatewayHeader(String)
    case url(String, String)
    case key(String, String)
    case save(String, Bool)
    case gatewayFooter(String)
    case stateHeader(String)
    case stateRow(Int32, String, String)
    case reconnect(String)
    case aboutHeader(String)
    case aboutText(String)
    case sources(String)

    var section: ItemListSectionId {
        switch self {
        case .intro, .pasteLink:
            return TGeshkaSettingsSection.intro.rawValue
        case .gatewayHeader, .url, .key, .save, .gatewayFooter:
            return TGeshkaSettingsSection.gateway.rawValue
        case .stateHeader, .stateRow, .reconnect:
            return TGeshkaSettingsSection.state.rawValue
        case .aboutHeader, .aboutText, .sources:
            return TGeshkaSettingsSection.about.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .intro:
            return 0
        case .pasteLink:
            return 1
        case .gatewayHeader:
            return 10
        case .url:
            return 11
        case .key:
            return 12
        case .save:
            return 13
        case .gatewayFooter:
            return 14
        case .stateHeader:
            return 20
        case let .stateRow(index, _, _):
            return 21 + index
        case .reconnect:
            return 40
        case .aboutHeader:
            return 50
        case .aboutText:
            return 51
        case .sources:
            return 52
        }
    }

    static func <(lhs: TGeshkaSettingsEntry, rhs: TGeshkaSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! TGeshkaSettingsArguments
        switch self {
        case let .intro(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .pasteLink(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.paste()
            })
        case let .gatewayHeader(text), let .stateHeader(text), let .aboutHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .url(placeholder, text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), sectionId: self.section, textUpdated: { value in
                arguments.updateUrl(value)
            }, action: {})
        case let .key(placeholder, text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(), text: text, placeholder: placeholder, type: .password, sectionId: self.section, textUpdated: { value in
                arguments.updateKey(value)
            }, action: {
                arguments.save()
            })
        case let .save(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.save()
            })
        case let .gatewayFooter(text), let .aboutText(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .stateRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .reconnect(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.reconnect()
            })
        case let .sources(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.openSources()
            })
        }
    }
}

private func formatBytes(_ value: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    return formatter.string(fromByteCount: value)
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "dd.MM HH:mm:ss"
    return formatter.string(from: date)
}

private func tgeshkaSettingsEntries(state: TGeshkaSettingsState, firstRun: Bool, hasPasteboardLink: Bool) -> [TGeshkaSettingsEntry] {
    var entries: [TGeshkaSettingsEntry] = []
    if firstRun {
        entries.append(.intro("TGeshka подключается к Telegram только через шлюз. Вставьте ключ доступа (tc_…), который вам выдали, или откройте ссылку tgeshka://gateway?…"))
    }
    if hasPasteboardLink {
        entries.append(.pasteLink("Вставить из буфера обмена"))
    }

    entries.append(.gatewayHeader("ШЛЮЗ"))
    entries.append(.url(TGeshkaGateway.defaultUrl.isEmpty ? "Адрес шлюза (wss://…)" : "Адрес по умолчанию", state.url))
    entries.append(.key("Ключ доступа tc_…", state.key))
    let keyValid = TGeshkaGateway.isValidKey(state.key)
    let urlValid = state.url.isEmpty ? !TGeshkaGateway.defaultUrl.isEmpty : TGeshkaGateway.isValidUrl(state.url)
    let checking: Bool
    if case .checking = state.check {
        checking = true
    } else {
        checking = false
    }
    entries.append(.save(checking ? "Проверка…" : "Сохранить и проверить", keyValid && urlValid && !checking))
    switch state.check {
    case .none, .checking:
        entries.append(.gatewayFooter("Адрес можно не заполнять: используется адрес по умолчанию. Ключ хранится только на этом устройстве."))
    case let .ok(info):
        entries.append(.gatewayFooter("Шлюз принял ключ: \(info.description.isEmpty ? "без описания" : info.description), ответ за \(info.rttMs) мс."))
    case let .failed(text):
        entries.append(.gatewayFooter("Проверка не прошла: \(text)"))
    }

    entries.append(.stateHeader("СОСТОЯНИЕ ШЛЮЗА"))
    let stats = state.stats
    let status: String
    if !TGeshkaGateway.shared.hasKey {
        status = "Нет ключа"
    } else if stats.activeConnections > 0 {
        status = "Подключено"
    } else {
        status = "Нет соединения"
    }
    entries.append(.stateRow(0, "Состояние", status))
    if let handshake = stats.lastHandshakeMs {
        entries.append(.stateRow(1, "Время подключения", "\(handshake) мс"))
    }
    var connections = "\(stats.activeConnections)"
    if case let .ok(info) = state.check, info.maxConnections > 0 {
        connections += " (на ключе \(info.activeConnections) из \(info.maxConnections))"
    }
    entries.append(.stateRow(2, "Соединения", connections))
    entries.append(.stateRow(3, "Получено", formatBytes(stats.bytesIn)))
    entries.append(.stateRow(4, "Отправлено", formatBytes(stats.bytesOut)))
    if let error = stats.lastError {
        let when = stats.lastErrorDate.flatMap { formatDate($0) } ?? ""
        entries.append(.stateRow(5, "Последняя ошибка", when.isEmpty ? error : "\(error), \(when)"))
    }
    entries.append(.reconnect("Переподключить"))

    entries.append(.aboutHeader("О TGESHKA"))
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    entries.append(.aboutText("TGeshka \(version) (\(build)) — неофициальный клиент Telegram на основе Telegram-iOS (GPLv2). Все соединения с Telegram идут через шлюз. Звонки пока подключаются напрямую."))
    entries.append(.sources("Исходный код"))
    return entries
}

private func pasteboardGatewaySettings() -> TGeshkaGatewaySettings? {
    guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        return nil
    }
    if let url = URL(string: text), let settings = TGeshkaGateway.parseLink(url) {
        return settings
    }
    if TGeshkaGateway.isValidKey(text) {
        return TGeshkaGatewaySettings(url: "", token: text)
    }
    return nil
}

public func tgeshkaSettingsController(context: AccountContext) -> ViewController {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    return tgeshkaSettingsController(sharedContext: context.sharedContext, presentationData: presentationData, updatedPresentationData: context.sharedContext.presentationData, firstRun: false)
}

public func tgeshkaSettingsController(sharedContext: SharedAccountContext, presentationData: PresentationData, updatedPresentationData: Signal<PresentationData, NoError>, firstRun: Bool, prefilled: TGeshkaGatewaySettings? = nil) -> ViewController {
    let current = prefilled ?? TGeshkaGateway.shared.settings
    let initialState = TGeshkaSettingsState(url: current.url, key: current.token, check: .none, stats: TGeshkaGateway.shared.currentStats)
    let stateValue = Atomic(value: initialState)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let updateState: ((TGeshkaSettingsState) -> TGeshkaSettingsState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let checkDisposable = MetaDisposable()
    var dismissImpl: (() -> Void)?
    var endEditingImpl: (() -> Void)?

    let save: () -> Void = {
        endEditingImpl?()
        let state = stateValue.with { $0 }
        let settings = TGeshkaGatewaySettings(url: state.url, token: state.key)
        updateState { current in
            var current = current
            current.check = .checking
            return current
        }
        checkDisposable.set((TGeshkaGateway.shared.fetchInfo(settings: settings)
        |> deliverOnMainQueue).start(next: { info in
            TGeshkaGateway.shared.update(settings)
            updateState { current in
                var current = current
                current.check = .ok(info)
                return current
            }
            if firstRun {
                dismissImpl?()
            }
        }, error: { error in
            let text: String
            switch error {
            case .noKey:
                text = "нет ключа"
            case .badUrl:
                text = "неверный адрес шлюза"
            case .rejected:
                text = "шлюз не принял ключ (опечатка или ключ отозван)"
            case let .network(description):
                text = "нет связи со шлюзом (\(description))"
            }
            updateState { current in
                var current = current
                current.check = .failed(text)
                return current
            }
        }))
    }

    let arguments = TGeshkaSettingsArguments(updateUrl: { value in
        updateState { current in
            var current = current
            current.url = value
            current.check = .none
            return current
        }
    }, updateKey: { value in
        updateState { current in
            var current = current
            current.key = value
            current.check = .none
            return current
        }
    }, paste: {
        guard let settings = pasteboardGatewaySettings() else {
            return
        }
        updateState { current in
            var current = current
            if !settings.url.isEmpty {
                current.url = settings.url
            }
            current.key = settings.token
            current.check = .none
            return current
        }
        save()
    }, save: {
        save()
    }, reconnect: {
        TGeshkaGateway.shared.reconnectAll()
    }, openSources: {
        if let url = URL(string: "https://github.com/SteepMans/tgeshka-ios") {
            sharedContext.applicationBindings.openUrl(url.absoluteString)
        }
    })

    let statsDisposable = (TGeshkaGateway.shared.statsSignal
    |> deliverOnMainQueue).start(next: { stats in
        updateState { current in
            var current = current
            current.stats = stats
            return current
        }
    })

    let hasPasteboardLink = pasteboardGatewaySettings() != nil

    let signal = combineLatest(updatedPresentationData, statePromise.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let leftNavigationButton: ItemListNavigationButton? = firstRun ? nil : ItemListNavigationButton(content: .icon(.close), style: .regular, enabled: true, action: {
            dismissImpl?()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(firstRun ? "Ключ доступа" : "TGeshka"), leftNavigationButton: leftNavigationButton, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: tgeshkaSettingsEntries(state: state, firstRun: firstRun, hasPasteboardLink: hasPasteboardLink), style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }
    |> afterDisposed {
        checkDisposable.dispose()
        statsDisposable.dispose()
    }

    let controller = ItemListController(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: updatedPresentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
    controller.navigationPresentation = .modal
    dismissImpl = { [weak controller] in
        let _ = controller?.dismiss()
    }
    endEditingImpl = { [weak controller] in
        controller?.view.endEditing(true)
    }
    return controller
}
