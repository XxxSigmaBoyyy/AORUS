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

private func aorusDataCenterName(_ dc: Int, _ ru: Bool) -> String {
    switch dc {
    case 1: return ru ? "DC1 · Майами, США" : "DC1 · Miami, USA"
    case 2: return ru ? "DC2 · Амстердам, Нидерланды" : "DC2 · Amsterdam, Netherlands"
    case 3: return ru ? "DC3 · Майами, США" : "DC3 · Miami, USA"
    case 4: return ru ? "DC4 · Амстердам, Нидерланды" : "DC4 · Amsterdam, Netherlands"
    case 5: return ru ? "DC5 · Сингапур" : "DC5 · Singapore"
    default: return ru ? "Неизвестно" : "Unknown"
    }
}

// Estimates an account's registration date from its numeric user id. Telegram
// ids grow roughly monotonically over time; this interpolates between known
// (id, date) anchor points. The result is approximate by design.
private func aorusEstimateRegistration(userId: Int64) -> Date? {
    // (user id → unix seconds) anchor points. Built from the public
    // jobians/telegram-id-age dataset of 212 real measured account samples,
    // then fitted to a strictly monotonic curve via isotonic regression
    // (pool-adjacent-violators) so Telegram's noisy multi-range id allocation
    // does not cause interpolation wobble. The last two points extrapolate the
    // measured 2025 growth rate forward to mid-2026.
    let anchors: [(Int64, Double)] = [
        (0, 1376438400),
        (2768409, 1383264000),
        (7679610, 1388448000),
        (11538514, 1391212800),
        (15835244, 1392854400),
        (23646077, 1393372800),
        (38015510, 1393632000),
        (44634663, 1399334400),
        (46145305, 1400112000),
        (54845238, 1411171200),
        (63263518, 1414368000),
        (101260938, 1425600000),
        (101323197, 1426204800),
        (103151531, 1432987200),
        (103258382, 1432987200),
        (109393468, 1434283200),
        (111220210, 1434283200),
        (112594714, 1438300800),
        (122600695, 1438300800),
        (124872445, 1439769600),
        (125828524, 1442620800),
        (130029930, 1442620800),
        (133909606, 1444176000),
        (143445125, 1448928000),
        (148670295, 1450800000),
        (157242073, 1450800000),
        (171295414, 1457481600),
        (181783990, 1460246400),
        (222021233, 1465344000),
        (225034354, 1466208000),
        (278941742, 1473465600),
        (285253072, 1476748800),
        (294851037, 1479513600),
        (297621225, 1481846400),
        (328594461, 1485561600),
        (337808429, 1487635200),
        (341546272, 1487721600),
        (352940995, 1487894400),
        (369669043, 1490918400),
        (400169472, 1501459200),
        (805158066, 1563148800),
        (1974255900, 1633996800),
        (5022636255, 1638921600),
        (5031711230, 1638921600),
        (5045293264, 1642032000),
        (5047148663, 1645833600),
        (5070164216, 1645833600),
        (5106451106, 1645963200),
        (5124771193, 1645963200),
        (5144324763, 1646006400),
        (5149590651, 1646006400),
        (5153900870, 1647129600),
        (5210565134, 1647129600),
        (5244529493, 1648454400),
        (5288930461, 1648454400),
        (5308260177, 1650844800),
        (5340744210, 1655694000),
        (5433708969, 1655694000),
        (5434011049, 1656460800),
        (5442755368, 1658435657),
        (5505809357, 1658435657),
        (5515826405, 1660240800),
        (5546930145, 1660240800),
        (5558980075, 1664409600),
        (5598262640, 1664409600),
        (5601951167, 1664668800),
        (5627539474, 1665259200),
        (5735455201, 1665259200),
        (5738347976, 1670630400),
        (5795660441, 1670630400),
        (5802659303, 1674561600),
        (5862080962, 1674561600),
        (5869978651, 1676851200),
        (5983753471, 1676851200),
        (5994561143, 1682848800),
        (6277658932, 1682848800),
        (6326011828, 1688688000),
        (6401027363, 1698969600),
        (6523424924, 1698969600),
        (6536173556, 1703937600),
        (6545049031, 1703937600),
        (6559717847, 1705894892),
        (6829119388, 1705894892),
        (6854829938, 1706745600),
        (6872061796, 1707652800),
        (6947316117, 1707652800),
        (7002435197, 1712361600),
        (7078066115, 1718179200),
        (7104310277, 1718179200),
        (7224009547, 1719748800),
        (7242296450, 1719748800),
        (7243375923, 1721260800),
        (7254607307, 1721260800),
        (7273085448, 1723564800),
        (7293965553, 1723564800),
        (7342300216, 1725904800),
        (7409259451, 1725904800),
        (7450316621, 1727827200),
        (7458668365, 1727827200),
        (7591351660, 1736363520),
        (7793034911, 1736363520),
        (7817256746, 1738419840),
        (7832006200, 1738419840),
        (7834356221, 1749729600),
        (7899152800, 1749729600),
        (7912577935, 1750329600),
        (8173852075, 1750329600),
        (8179125032, 1752019200),
        (8200159552, 1757088000),
        (8369442459, 1757088000),
        (8384648263, 1760025600),
        (8461579295, 1760025600),
        (8480708838, 1762300800),
        (8559682245, 1762819200),
        (8800041957, 1771113600),
        (9022875441, 1778803200),
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

private func aorusAccountAge(from date: Date, _ ru: Bool) -> String {
    let comps = Calendar.current.dateComponents([.year, .month], from: date, to: Date())
    let years = comps.year ?? 0
    let months = comps.month ?? 0
    if ru {
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
    } else {
        func unit(_ n: Int, _ u: String) -> String { return "\(n) \(u)\(n == 1 ? "" : "s")" }
        if years <= 0 {
            return unit(months, "month")
        }
        return "\(unit(years, "year")) \(unit(months, "month"))"
    }
}

// MARK: - Entries builder

private func accountDetailEntries(theme: PresentationTheme, entityId: Int64, dcId: Int,
                                  kind: AorusDetailKind, creationDate: Int32, ru: Bool) -> [AccountDetailEntry] {
    var entries: [AccountDetailEntry] = []

    let sectionTitle: String
    let idLabel: String
    let ageLabel: String
    let dateLabel: String
    let isExact: Bool
    switch kind {
    case .user:
        sectionTitle = ru ? "АККАУНТ" : "ACCOUNT"; idLabel = ru ? "ID аккаунта" : "Account ID"; ageLabel = ru ? "Возраст аккаунта" : "Account Age"
        dateLabel = ru ? "Дата (примерно)" : "Date (approx.)"; isExact = false
    case .channel:
        sectionTitle = ru ? "КАНАЛ" : "CHANNEL"; idLabel = ru ? "ID канала" : "Channel ID"; ageLabel = ru ? "Возраст канала" : "Channel Age"
        dateLabel = ru ? "Дата создания" : "Creation Date"; isExact = true
    case .group:
        sectionTitle = ru ? "ГРУППА" : "GROUP"; idLabel = ru ? "ID чата" : "Chat ID"; ageLabel = ru ? "Возраст чата" : "Chat Age"
        dateLabel = ru ? "Дата создания" : "Creation Date"; isExact = true
    }

    entries.append(.accountHeader(theme, sectionTitle))
    entries.append(.idRow(theme, idLabel, "\(entityId)"))
    entries.append(.dcRow(theme, ru ? "Дата-центр" : "Data Center", dcId > 0 ? aorusDataCenterName(dcId, ru) : (ru ? "Неизвестно" : "Unknown")))

    // Users: estimated from the numeric id. Channels / groups: the exact
    // creationDate provided directly by Telegram.
    let date: Date?
    if isExact {
        date = creationDate > 0 ? Date(timeIntervalSince1970: Double(creationDate)) : nil
    } else {
        date = aorusEstimateRegistration(userId: entityId)
    }

    entries.append(.regHeader(theme, isExact ? (ru ? "СОЗДАНИЕ" : "CREATION") : (ru ? "РЕГИСТРАЦИЯ" : "REGISTRATION")))
    if let date = date {
        let df = DateFormatter()
        df.locale = Locale(identifier: ru ? "ru_RU" : "en_US")
        df.dateFormat = isExact ? "d MMMM yyyy" : "LLLL yyyy"
        entries.append(.regDateRow(theme, dateLabel, df.string(from: date)))
        entries.append(.ageRow(theme, ageLabel, aorusAccountAge(from: date, ru)))
    } else {
        entries.append(.regDateRow(theme, dateLabel, ru ? "Неизвестно" : "Unknown"))
    }

    entries.append(.footer(theme, isExact
        ? (ru ? "Дата создания получена напрямую из данных Telegram."
              : "The creation date is taken directly from Telegram's data.")
        : (ru ? "Дата регистрации не предоставляется Telegram API и вычисляется приблизительно по ID аккаунта. Возможна погрешность в несколько месяцев."
              : "The registration date is not provided by the Telegram API and is estimated from the account ID. It may be off by a few months.")))

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
        let ru = AorusLang.current == .ru
        let alert = textAlertController(
            context: context,
            title: nil,
            text: ru ? "ID скопирован в буфер обмена" : "ID copied to clipboard",
            actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]
        )
        controller.present(alert, in: .window(.root))
    })

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, Any)), NoError> = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let ru = AorusLang.resolve(presentationData.strings.baseLanguageCode) == .ru
            let entries = accountDetailEntries(theme: presentationData.theme, entityId: entityId, dcId: dcId, kind: kind, creationDate: creationDate, ru: ru)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(title.isEmpty ? (ru ? "Подробнее" : "Details") : title),
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
