import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

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
        switch self {
        case let .accountHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .idRow(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
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
    let anchors: [(Int64, Double)] = [
        (100000, 1375315200),
        (1000000, 1380585600),
        (5000000, 1388534400),
        (10000000, 1401580800),
        (20000000, 1412121600),
        (50000000, 1433116800),
        (77000000, 1451606400),
        (100000000, 1462060800),
        (130000000, 1480550400),
        (150000000, 1488326400),
        (200000000, 1506816000),
        (250000000, 1522540800),
        (300000000, 1535760000),
        (350000000, 1546300800),
        (400000000, 1559347200),
        (450000000, 1572566400),
        (500000000, 1580515200),
        (600000000, 1596240000),
        (700000000, 1604188800),
        (800000000, 1609459200),
        (900000000, 1614556800),
        (1000000000, 1619827200),
        (1200000000, 1627776000),
        (1400000000, 1635724800),
        (1600000000, 1643673600),
        (1900000000, 1656633600),
        (2300000000, 1672531200),
        (2800000000, 1685577600),
        (3400000000, 1698796800),
        (4000000000, 1706745600),
        (4700000000, 1717200000),
        (5400000000, 1727740800),
        (6200000000, 1740787200),
        (7000000000, 1756684800),
    ]
    guard userId > 0, let first = anchors.first, let last = anchors.last else { return nil }
    if userId <= first.0 { return Date(timeIntervalSince1970: first.1) }
    if userId >= last.0 { return Date(timeIntervalSince1970: last.1) }
    for i in 1 ..< anchors.count {
        let (id0, t0) = anchors[i - 1]
        let (id1, t1) = anchors[i]
        if userId >= id0 && userId <= id1 {
            let frac = Double(userId - id0) / Double(id1 - id0)
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

private func accountDetailEntries(theme: PresentationTheme, userId: Int64, dcId: Int) -> [AccountDetailEntry] {
    var entries: [AccountDetailEntry] = []

    entries.append(.accountHeader(theme, "АККАУНТ"))
    entries.append(.idRow(theme, "🆔 ID аккаунта", "\(userId)"))
    entries.append(.dcRow(theme, "🌐 Дата-центр", dcId > 0 ? aorusDataCenterName(dcId) : "Неизвестно"))

    entries.append(.regHeader(theme, "РЕГИСТРАЦИЯ"))
    if let date = aorusEstimateRegistration(userId: userId) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "LLLL yyyy"
        entries.append(.regDateRow(theme, "📅 Дата (примерно)", df.string(from: date)))
        entries.append(.ageRow(theme, "⏳ Возраст аккаунта", aorusAccountAge(from: date)))
    } else {
        entries.append(.regDateRow(theme, "📅 Дата (примерно)", "Неизвестно"))
    }

    entries.append(.footer(theme,
        "Дата регистрации не предоставляется Telegram API и вычисляется "
        + "приблизительно по ID аккаунта. Возможна погрешность в несколько месяцев."))

    return entries
}

// MARK: - Public factory

private final class AccountDetailArguments {}

public func accountDetailsController(context: AccountContext, userId: Int64, dcId: Int, title: String) -> ViewController {
    let signal: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let entries = accountDetailEntries(theme: presentationData.theme, userId: userId, dcId: dcId)
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
            return (controllerState, (listState, AccountDetailArguments()))
        }

    return ItemListController(context: context, state: signal)
}
