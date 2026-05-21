import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Kind

public enum AorusDetailKind {
    case user
    case channel
    case group
}

// MARK: - Sections

private enum DetailSection: Int32 {
    case account
    case registration
    case footer
}

// MARK: - Entries

private enum AccountDetailEntry: ItemListNodeEntry {
    case accountHeader(PresentationTheme, String)
    case idRow(PresentationTheme, String, String)
    case dcRow(PresentationTheme, String, String)

    case regHeader(PresentationTheme, String)
    case regDateRow(PresentationTheme, String, String)
    case ageRow(PresentationTheme, String, String)

    case footer(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .accountHeader, .idRow, .dcRow:
            return DetailSection.account.rawValue
        case .regHeader, .regDateRow, .ageRow:
            return DetailSection.registration.rawValue
        case .footer:
            return DetailSection.footer.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .accountHeader: return 0
        case .idRow:         return 1
        case .dcRow:         return 2
        case .regHeader:     return 3
        case .regDateRow:    return 4
        case .ageRow:        return 5
        case .footer:        return 6
        }
    }

    static func < (lhs: AccountDetailEntry, rhs: AccountDetailEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AccountDetailEntry, rhs: AccountDetailEntry) -> Bool {
        switch lhs {
        case let .accountHeader(lt, ls):
            if case let .accountHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .idRow(lt, lk, lv):
            if case let .idRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .dcRow(lt, lk, lv):
            if case let .dcRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .regHeader(lt, ls):
            if case let .regHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .regDateRow(lt, lk, lv):
            if case let .regDateRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .ageRow(lt, lk, lv):
            if case let .ageRow(rt, rk, rv) = rhs { return lt === rt && lk == rk && lv == rv }
        case let .footer(lt, ls):
            if case let .footer(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! AccountDetailArguments
        switch self {
        case let .accountHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .idRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: { args.copyId() })
        case let .dcRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .regHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .regDateRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .ageRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .footer(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        }
    }
}

// MARK: - Estimation helpers

private func aorusDataCenterName(_ dc: Int) -> String {
    switch dc {
    case 1: return "DC1 · Майами, США"
    case 2: return "DC2 · Амстердам, Нидерланды"
    case 3: return "DC3 · Майами, США"
    case 4: return "DC4 · Амстердам, Нидерланды"
    case 5: return "DC5 · Сингапур"
    default: return "Неизвестно"
    }
}

// Estimates an account's registration date from its numeric user id. Telegram
// ids grow roughly monotonically over time; this interpolates between known
// (id, date) anchor points. The result is approximate by design.
private func aorusEstimateRegistration(userId: Int64) -> Date? {
    // Hand-calibrated (user id → unix seconds) anchor points covering the
    // launch of Telegram (Aug 2013) through early 2026. Sorted by id, smooth
    // monotonic growth curve. Beyond the last anchor the newest date is
    // returned — no forward extrapolation, which previously projected ordinary
    // accounts onto "now" and reported them as 0 months old.
    let anchors: [(Int64, Double)] = [
        (50000, 1375315200),
        (8000000, 1385856000),
        (22000000, 1401580800),
        (42000000, 1417392000),
        (62000000, 1433116800),
        (88000000, 1451606400),
        (118000000, 1470009600),
        (150000000, 1488326400),
        (195000000, 1506816000),
        (245000000, 1522540800),
        (300000000, 1538352000),
        (360000000, 1554076800),
        (430000000, 1569888000),
        (520000000, 1583020800),
        (660000000, 1598918400),
        (780000000, 1609459200),
        (950000000, 1619827200),
        (1300000000, 1630454400),
        (1800000000, 1640995200),
        (2400000000, 1656633600),
        (3100000000, 1672531200),
        (3900000000, 1688169600),
        (4600000000, 1704067200),
        (5400000000, 1722470400),
        (6300000000, 1738368000),
        (7200000000, 1754006400),
        (8100000000, 1769904000),
    ]
    guard userId > 0, let first = anchors.first, let last = anchors.last else { return nil }
    if userId <= first.0 { return Date(timeIntervalSince1970: first.1) }
    if userId >= last.0 { return Date(timeIntervalSince1970: last.1) }
    for i in 1 ..< anchors.count {
        let (id0, t0) = anchors[i - 1]
        let (id1, t1) = anchors[i]
        if userId >= id0 && userId <= id1 {
            let frac = id1 > id0 ? Double(userId - id0) / Double(id1 - id0) : 0
            return Date(timeIntervalSince1970: t0 + frac * (t1 - t0))
        }
    }
    return nil
}

private func aorusAccountAge(from date: Date) -> String {
    let comps = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
    let years = comps.year ?? 0
    let months = comps.month ?? 0
    func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return one }
        if m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14) { return few }
        return many
    }
    if years <= 0 {
        return "\(months) \(plural(months, "месяц", "месяца", "месяцев"))"
    }
    return "\(years) \(plural(years, "год", "года", "лет")) \(months) \(plural(months, "месяц", "месяца", "месяцев"))"
}

// MARK: - Entries builder

private func accountDetailEntries(theme: PresentationTheme, entityId: Int64, dcId: Int,
                                  kind: AorusDetailKind, creationDate: Int32) -> [AccountDetailEntry] {
    var entries: [AccountDetailEntry] = []

    let sectionTitle: String
    let idLabel: String
    let ageLabel: String
    let dateLabel: String
    let isExact: Bool
    switch kind {
    case .user:
        sectionTitle = "АККАУНТ"; idLabel = "ID аккаунта"; ageLabel = "Возраст аккаунта"
        dateLabel = "Дата (примерно)"; isExact = false
    case .channel:
        sectionTitle = "КАНАЛ"; idLabel = "ID канала"; ageLabel = "Возраст канала"
        dateLabel = "Дата создания"; isExact = true
    case .group:
        sectionTitle = "ГРУППА"; idLabel = "ID чата"; ageLabel = "Возраст чата"
        dateLabel = "Дата создания"; isExact = true
    }

    entries.append(.accountHeader(theme, sectionTitle))
    entries.append(.idRow(theme, idLabel, "\(entityId)"))
    entries.append(.dcRow(theme, "Дата-центр", dcId > 0 ? aorusDataCenterName(dcId) : "Неизвестно"))

    // Users: estimated from the numeric id. Channels / groups: the exact
    // creationDate provided directly by Telegram.
    let date: Date?
    if isExact {
        date = creationDate > 0 ? Date(timeIntervalSince1970: Double(creationDate)) : nil
    } else {
        date = aorusEstimateRegistration(userId: entityId)
    }

    entries.append(.regHeader(theme, isExact ? "СОЗДАНИЕ" : "РЕГИСТРАЦИЯ"))
    if let date = date {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = isExact ? "d MMMM yyyy" : "LLLL yyyy"
        entries.append(.regDateRow(theme, dateLabel, df.string(from: date)))
        entries.append(.ageRow(theme, ageLabel, aorusAccountAge(from: date)))
    } else {
        entries.append(.regDateRow(theme, dateLabel, "Неизвестно"))
    }

    entries.append(.footer(theme, isExact
        ? "Дата создания получена напрямую из данных Telegram."
        : "Дата регистрации не предоставляется Telegram API и вычисляется "
          + "приблизительно по ID аккаунта. Возможна погрешность в несколько месяцев."))

    return entries
}

// MARK: - Public factory

private final class AccountDetailArguments {
    let copyId: () -> Void
    init(copyId: @escaping () -> Void) {
        self.copyId = copyId
    }
}

public func accountDetailsController(context: AccountContext, entityId: Int64, dcId: Int, title: String, kind: AorusDetailKind, creationDate: Int32) -> ViewController {
    weak var weakController: ItemListController?

    let arguments = AccountDetailArguments(copyId: {
        UIPasteboard.general.string = "\(entityId)"
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        guard let controller = weakController else { return }
        let alert = textAlertController(
            context: context,
            title: nil,
            text: "ID скопирован в буфер обмена",
            actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]
        )
        controller.present(alert, in: .window(.root))
    })

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let entries = accountDetailEntries(theme: presentationData.theme, entityId: entityId, dcId: dcId, kind: kind, creationDate: creationDate)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(title.isEmpty ? "Подробнее" : title),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks
            )
            return (controllerState, (listState, arguments))
        }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
