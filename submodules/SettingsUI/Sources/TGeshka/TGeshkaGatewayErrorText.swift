import Foundation
import TelegramCore

// TGeshka: the last gateway error in words of the user, what happened and what to do.
// Close codes: SteepMans/api-gateway internal/tunnel/server.go (protocol v1).

func tgeshkaGatewayErrorText(_ kind: TGeshkaGatewayErrorKind?) -> String {
    guard let kind = kind else {
        return "Соединение со шлюзом прервалось. Приложение переподключится само."
    }
    switch kind {
    case .noKey:
        return "Нет ключа доступа: вставьте ключ, который вам выдали, в поле выше."
    case .badUrl:
        return "Неверный адрес шлюза: очистите поле адреса или вставьте ссылку tgeshka:// заново."
    case .timeout:
        return "Шлюз не ответил вовремя, обычно из-за медленной сети. Приложение переподключится само."
    case .refused:
        return "Шлюз не принял соединение. Если повторяется, проверьте ключ доступа или напишите владельцу шлюза."
    case .network:
        return "Нет связи со шлюзом: проверьте интернет. Приложение переподключится само."
    case .tls:
        return "Не получилось установить защищённое соединение со шлюзом. Проверьте дату и время на телефоне или смените сеть."
    case .dns:
        return "Не удалось найти адрес шлюза. Проверьте интернет или переключитесь между Wi-Fi и мобильной сетью."
    case let .closed(code):
        switch code {
        case 4401:
            return "Ключ доступа отозван. Попросите у владельца шлюза новый ключ и вставьте его выше."
        case 4429:
            return "С этим ключом открыто слишком много соединений. Закройте TGeshka на других устройствах или попросите владельца шлюза поднять лимит."
        case 4502:
            return "Заграничные узлы недоступны: шлюз переключится сам, ничего делать не нужно."
        case 4504:
            return "Шлюз не достучался до серверов Telegram. Обычно это проходит само за минуту."
        case 4400:
            return "Шлюз не понял начало соединения. Обновите TGeshka, а если не поможет, напишите владельцу шлюза."
        case 4408:
            return "Шлюз закрыл соединение, которое долго молчало. Это нормально, приложение переподключится само."
        case 1011:
            return "Внутренняя ошибка шлюза. Приложение переподключится само, а если повторяется, напишите владельцу шлюза."
        default:
            return "Шлюз закрыл соединение. Приложение переподключится само."
        }
    case .other:
        return "Соединение со шлюзом прервалось. Приложение переподключится само."
    }
}

/// "только что", "5 мин назад" within an hour, otherwise "в 11:20" (or "23.11 в 11:20" not today).
func tgeshkaErrorTimeText(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 {
        return "только что"
    }
    if seconds < 3600 {
        return "\(Int(seconds / 60)) мин назад"
    }
    return tgeshkaClockText(date, now: now)
}

/// "в 11:20", or "23.11 в 11:20" when not today.
func tgeshkaClockText(_ date: Date, now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.dateFormat = "HH:mm"
    let time = formatter.string(from: date)
    if Calendar.current.isDate(date, inSameDayAs: now) {
        return "в " + time
    }
    formatter.dateFormat = "dd.MM"
    return formatter.string(from: date) + " в " + time
}

/// The text for "Copy": the exact error, when it happened and the app version.
func tgeshkaErrorDetailsText(stats: TGeshkaGatewayStats) -> String {
    var lines: [String] = []
    lines.append(stats.lastError ?? "")
    if let kind = stats.lastErrorKind {
        lines.append("kind: \(kind)")
    }
    if let date = stats.lastErrorDate {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        lines.append("time: " + formatter.string(from: date))
    }
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
    lines.append("TGeshka iOS \(version) (\(build)), connections: \(stats.activeConnections)")
    return lines.joined(separator: "\n")
}
