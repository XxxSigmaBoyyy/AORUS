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
    case copyIdAction(PresentationTheme, String)
    case dcRow(PresentationTheme, String, String)

    case regHeader(PresentationTheme, String)
    case regDateRow(PresentationTheme, String, String)
    case ageRow(PresentationTheme, String, String)

    case footer(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .accountHeader, .idRow, .copyIdAction, .dcRow:
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
        case .copyIdAction:  return 2
        case .dcRow:         return 3
        case .regHeader:     return 4
        case .regDateRow:    return 5
        case .ageRow:        return 6
        case .footer:        return 7
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
        case let .copyIdAction(lt, ls):
            if case let .copyIdAction(rt, rs) = rhs { return lt === rt && ls == rs }
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
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: value, sectionId: section, style: .blocks, disclosureStyle: .none, action: nil)
        case let .copyIdAction(_, text):
            return ItemListActionItem(presentationData: presentationData, title: text, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: { args.copyId() })
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
    // 44 real measured (account id → creation timestamp) samples from the
    // public lastochkin-group/telegram-account-age-estimator dataset. Sorted by
    // id with the timestamps clamped to be non-decreasing. For ids past the
    // newest sample we extrapolate with the slope of the last two anchors
    // instead of clamping to a fixed date (the clamp made every new account
    // read as "1 month old").
    let anchors: [(Int64, Double)] = [
        (2768409, 1383264000),
        (7679610, 1388448000),
        (11538514, 1391212000),
        (15835244, 1392940000),
        (23646077, 1393459000),
        (38015510, 1393632000),
        (44634663, 1399334000),
        (46145305, 1400198000),
        (54845238, 1411257000),
        (63263518, 1414454000),
        (101260938, 1425600000),
        (101323197, 1426204000),
        (103151531, 1433376000),
        (103258382, 1433376000),
        (109393468, 1439078000),
        (111220210, 1439078000),
        (112594714, 1439683000),
        (116812045, 1439683000),
        (122600695, 1439683000),
        (124872445, 1439856000),
        (125828524, 1444003000),
        (130029930, 1444003000),
        (133909606, 1444176000),
        (143445125, 1448928000),
        (148670295, 1452211000),
        (152079341, 1453420000),
        (157242073, 1453420000),
        (171295414, 1457481000),
        (181783990, 1460246000),
        (222021233, 1465344000),
        (225034354, 1466208000),
        (278941742, 1473465000),
        (285253072, 1476835000),
        (294851037, 1479600000),
        (297621225, 1481846000),
        (328594461, 1482969000),
        (337808429, 1487707000),
        (341546272, 1487782000),
        (352940995, 1487894000),
        (369669043, 1490918000),
        (400169472, 1501459000),
        (805158066, 1563208000),
        (1974255900, 1634000000),
        (5520018289, 1721847912),
    ]
    guard userId > 0, anchors.count >= 2,
          let first = anchors.first, let last = anchors.last else { return nil }
    if userId <= first.0 { return Date(timeIntervalSince1970: first.1) }
    if userId >= last.0 {
        // Extrapolate forward using the slope of the last two samples; never
        // return a date in the future.
        let prev = anchors[anchors.count - 2]
        let idSpan = Double(last.0 - prev.0)
        let timeSpan = last.1 - prev.1
        guard idSpan > 0, timeSpan > 0 else { return Date(timeIntervalSince1970: last.1) }
        let secondsPerId = timeSpan / idSpan
        let projected = last.1 + Double(userId - last.0) * secondsPerId
        return Date(timeIntervalSince1970: min(projected, Date().timeIntervalSince1970))
    }
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

private func accountDetailEntries(theme: PresentationTheme, userId: Int64, dcId: Int) -> [AccountDetailEntry] {
    var entries: [AccountDetailEntry] = []

    entries.append(.accountHeader(theme, "АККАУНТ"))
    entries.append(.idRow(theme, "ID аккаунта", "\(userId)"))
    entries.append(.copyIdAction(theme, "Скопировать ID"))
    entries.append(.dcRow(theme, "Дата-центр", dcId > 0 ? aorusDataCenterName(dcId) : "Неизвестно"))

    entries.append(.regHeader(theme, "РЕГИСТРАЦИЯ"))
    if let date = aorusEstimateRegistration(userId: userId) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "LLLL yyyy"
        entries.append(.regDateRow(theme, "Дата (примерно)", df.string(from: date)))
        entries.append(.ageRow(theme, "Возраст аккаунта", aorusAccountAge(from: date)))
    } else {
        entries.append(.regDateRow(theme, "Дата (примерно)", "Неизвестно"))
    }

    entries.append(.footer(theme,
        "Дата регистрации не предоставляется Telegram API и вычисляется "
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

public func accountDetailsController(context: AccountContext, userId: Int64, dcId: Int, title: String) -> ViewController {
    weak var weakController: ItemListController?

    let arguments = AccountDetailArguments(copyId: {
        UIPasteboard.general.string = "\(userId)"
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
            return (controllerState, (listState, arguments))
        }

    let controller = ItemListController(context: context, state: signal)
    weakController = controller
    return controller
}
