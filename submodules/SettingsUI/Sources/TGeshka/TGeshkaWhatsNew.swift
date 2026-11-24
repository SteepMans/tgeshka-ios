import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import TextFormat
import AccountContext

// TGeshka "What's new": the changes of the client from CHANGELOG-tgeshka.json in the repository root,
// bundled as an app resource (Telegram/BUILD), so it opens without the network.

public struct TGeshkaRelease: Equatable {
    public let version: String
    public let date: String
    public let items: [String]
}

public func tgeshkaChangelog() -> [TGeshkaRelease] {
    guard let url = Bundle.main.url(forResource: "CHANGELOG-tgeshka", withExtension: "json"), let data = try? Data(contentsOf: url) else {
        return []
    }
    guard let array = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]] else {
        return []
    }
    var result: [TGeshkaRelease] = []
    for object in array {
        guard let version = object["version"] as? String, !version.isEmpty else {
            continue
        }
        let items = ((object["items"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        if items.isEmpty {
            continue
        }
        result.append(TGeshkaRelease(version: version, date: (object["date"] as? String) ?? "", items: items))
    }
    return result
}

public func tgeshkaAppVersion() -> String {
    return (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
}

private func tgeshkaBaseVersion(_ version: String) -> String {
    return version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
}

/// The entry of the version, or of the same version without a beta suffix.
private func tgeshkaFindRelease(_ releases: [TGeshkaRelease], version: String) -> TGeshkaRelease? {
    if let release = releases.first(where: { $0.version == version }) {
        return release
    }
    let base = tgeshkaBaseVersion(version)
    return releases.first(where: { tgeshkaBaseVersion($0.version) == base })
}

/// 2026-11-23 -> 23.11.2026
private func tgeshkaFormatDate(_ date: String) -> String {
    let parts = date.split(separator: "-")
    if parts.count == 3 {
        return "\(parts[2]).\(parts[1]).\(parts[0])"
    }
    return date
}

public func tgeshkaWhatsNewText(_ release: TGeshkaRelease) -> String {
    return release.items.map { "• \($0)" }.joined(separator: "\n")
}

private let tgeshkaWhatsNewSeenKey = "tgeshka.whatsNew.seen"

/// The release to show once after an update, or nil. A fresh install (no gateway key yet) only remembers it.
public func tgeshkaWhatsNewReleaseToShow() -> TGeshkaRelease? {
    guard let release = tgeshkaFindRelease(tgeshkaChangelog(), version: tgeshkaAppVersion()) else {
        return nil
    }
    let seen = UserDefaults.standard.string(forKey: tgeshkaWhatsNewSeenKey) ?? ""
    if seen == release.version {
        return nil
    }
    if seen.isEmpty && !TGeshkaGateway.shared.hasKey {
        tgeshkaMarkWhatsNewShown(release)
        return nil
    }
    return release
}

public func tgeshkaMarkWhatsNewShown(_ release: TGeshkaRelease) {
    UserDefaults.standard.set(release.version, forKey: tgeshkaWhatsNewSeenKey)
}

private enum TGeshkaWhatsNewEntry: ItemListNodeEntry {
    case header(Int32, String)
    case items(Int32, String)
    case empty(String)

    var section: ItemListSectionId {
        switch self {
        case let .header(index, _), let .items(index, _):
            return index
        case .empty:
            return 0
        }
    }

    var stableId: Int32 {
        switch self {
        case let .header(index, _):
            return index * 2
        case let .items(index, _):
            return index * 2 + 1
        case .empty:
            return 0
        }
    }

    static func <(lhs: TGeshkaWhatsNewEntry, rhs: TGeshkaWhatsNewEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .header(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .items(_, text):
            return ItemListMultilineTextItem(presentationData: presentationData, text: text, enabledEntityTypes: [], sectionId: self.section, style: .blocks)
        case let .empty(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func tgeshkaWhatsNewEntries(_ releases: [TGeshkaRelease]) -> [TGeshkaWhatsNewEntry] {
    if releases.isEmpty {
        return [.empty("Список изменений недоступен.")]
    }
    var entries: [TGeshkaWhatsNewEntry] = []
    for (index, release) in releases.enumerated() {
        var title = release.version
        if !release.date.isEmpty {
            title += " · " + tgeshkaFormatDate(release.date)
        }
        entries.append(.header(Int32(index), title))
        entries.append(.items(Int32(index), tgeshkaWhatsNewText(release)))
    }
    return entries
}

/// Settings → TGeshka → What's new: every version, newest first.
public func tgeshkaWhatsNewController(sharedContext: SharedAccountContext) -> ViewController {
    let presentationData = sharedContext.currentPresentationData.with { $0 }
    let entries = tgeshkaWhatsNewEntries(tgeshkaChangelog())
    let signal = sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Что нового"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, 0))
    }
    return ItemListController(presentationData: ItemListPresentationData(presentationData), updatedPresentationData: sharedContext.presentationData |> map(ItemListPresentationData.init(_:)), state: signal, tabBarItem: nil)
}
