import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Sections

private enum BackupSection: Int32 {
    case actions
    case info
    case status
    case sessions
}

// MARK: - State

private struct BackupState: Equatable {
    // Bumped after every backup / restore / delete so the list rebuilds from
    // the fresh AccountBackupManager values.
    var revision: Int
    var busy: Bool
}

// MARK: - Arguments

private final class BackupArguments {
    let backup: () -> Void
    let restore: () -> Void
    let delete: () -> Void

    init(backup: @escaping () -> Void,
         restore: @escaping () -> Void,
         delete: @escaping () -> Void) {
        self.backup = backup
        self.restore = restore
        self.delete = delete
    }
}

// MARK: - Entries

private enum BackupEntry: ItemListNodeEntry {
    case backupAction(PresentationTheme, String, Bool)
    case restoreAction(PresentationTheme, String, Bool)
    case deleteAction(PresentationTheme, String, Bool)

    case info(PresentationTheme, String)

    case statusHeader(PresentationTheme, String)
    case status(PresentationTheme, String)

    case sessionsHeader(PresentationTheme, String)
    case session(PresentationTheme, Int32, String)

    var section: ItemListSectionId {
        switch self {
        case .backupAction, .restoreAction, .deleteAction:
            return BackupSection.actions.rawValue
        case .info:
            return BackupSection.info.rawValue
        case .statusHeader, .status:
            return BackupSection.status.rawValue
        case .sessionsHeader, .session:
            return BackupSection.sessions.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .backupAction:   return 0
        case .restoreAction:  return 1
        case .deleteAction:   return 2
        case .info:           return 3
        case .statusHeader:   return 4
        case .status:         return 5
        case .sessionsHeader: return 6
        case let .session(_, index, _): return 100 + index
        }
    }

    static func < (lhs: BackupEntry, rhs: BackupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: BackupEntry, rhs: BackupEntry) -> Bool {
        switch lhs {
        case let .backupAction(lt, ls, lv):
            if case let .backupAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .restoreAction(lt, ls, lv):
            if case let .restoreAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .deleteAction(lt, ls, lv):
            if case let .deleteAction(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .info(lt, ls):
            if case let .info(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .statusHeader(lt, ls):
            if case let .statusHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .status(lt, ls):
            if case let .status(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .sessionsHeader(lt, ls):
            if case let .sessionsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .session(lt, li, ls):
            if case let .session(rt, ri, rs) = rhs { return lt === rt && li == ri && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! BackupArguments
        switch self {
        case let .backupAction(_, title, enabled):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: section, style: .blocks, action: { if enabled { args.backup() } })
        case let .restoreAction(_, title, enabled):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: section, style: .blocks, action: { if enabled { args.restore() } })
        case let .deleteAction(_, title, enabled):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: enabled ? .destructive : .disabled, alignment: .natural, sectionId: section, style: .blocks, action: { if enabled { args.delete() } })
        case let .info(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .statusHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .status(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .sessionsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .session(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        }
    }
}

// MARK: - Entries builder

private func backupEntries(state: BackupState, theme: PresentationTheme) -> [BackupEntry] {
    let mgr = AccountBackupManager.shared
    let hasBackup = mgr.hasBackup()
    var entries: [BackupEntry] = []

    entries.append(.backupAction(theme, "Бэкап в Keychain", !state.busy))
    entries.append(.restoreAction(theme, "Восстановить из Keychain", hasBackup && !state.busy))
    entries.append(.deleteAction(theme, "Удалить Бэкап из Keychain", hasBackup && !state.busy))

    entries.append(.info(theme,
        "Сессии шифруются (AES-256) и хранятся в Keychain устройства. "
        + "Сессии никогда не покидают ваше устройство.\n\n"
        + "ВАЖНО: Чтобы восстановить сессии на новом устройстве или после "
        + "сброса системы, ОБЯЗАТЕЛЬНО включите шифрование резервных копий ОС, "
        + "иначе Keychain будет утерян при восстановлении.\n\n"
        + "ПРИМЕЧАНИЕ: Сессии всё ещё могут быть разлогинены самим Telegram "
        + "или с другого устройства."))

    entries.append(.statusHeader(theme, "СОСТОЯНИЕ"))
    if state.busy {
        entries.append(.status(theme, "Выполняется операция…"))
    } else if mgr.isRestorePending() {
        entries.append(.status(theme, "Бэкап подготовлен к восстановлению.\nПерезапустите приложение для применения."))
    } else if let info = mgr.backupInfo() {
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy HH:mm"
        let size = ByteCountFormatter.string(fromByteCount: info.sizeBytes, countStyle: .file)
        entries.append(.status(theme,
            "Бэкап от \(df.string(from: info.date))\nАккаунтов: \(info.accountCount) · Размер: \(size)"))
    } else {
        entries.append(.status(theme, "Бэкап ещё не создан."))
    }

    entries.append(.sessionsHeader(theme, "СЕССИИ"))
    let ids = mgr.localAccountIds()
    if ids.isEmpty {
        entries.append(.session(theme, 0, "Нет активных сессий"))
    } else {
        for (i, id) in ids.enumerated() {
            entries.append(.session(theme, Int32(i), "Аккаунт · \(id)"))
        }
    }

    return entries
}

// MARK: - Public factory

public func accountBackupController(context: AccountContext) -> ViewController {
    let initialState = BackupState(revision: 0, busy: false)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let updateState: ((BackupState) -> BackupState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    weak var weakController: ItemListController?

    let presentAlert: (String, String) -> Void = { title, text in
        guard let controller = weakController else { return }
        let alert = textAlertController(
            context: context,
            title: title,
            text: text,
            actions: [TextAlertAction(type: .defaultAction, title: "OK", action: {})]
        )
        controller.present(alert, in: .window(.root))
    }

    let refresh: () -> Void = {
        updateState { current in
            var next = current
            next.revision += 1
            next.busy = false
            return next
        }
    }

    let runBusy: (@escaping () -> Void) -> Void = { work in
        updateState { current in
            var next = current
            next.busy = true
            return next
        }
        DispatchQueue.global(qos: .userInitiated).async {
            work()
        }
    }

    let arguments = BackupArguments(
        backup: {
            guard let controller = weakController else { return }
            let confirm = textAlertController(
                context: context,
                title: "Создать бэкап?",
                text: "Текущие сессии будут зашифрованы и сохранены в Keychain устройства.",
                actions: [
                    TextAlertAction(type: .genericAction, title: "Отмена", action: {}),
                    TextAlertAction(type: .defaultAction, title: "Создать", action: {
                        runBusy {
                            let result = AccountBackupManager.shared.performBackup()
                            DispatchQueue.main.async {
                                refresh()
                                switch result {
                                case let .success(info):
                                    presentAlert("Готово", "Бэкап создан. Аккаунтов: \(info.accountCount).")
                                case let .failure(message):
                                    presentAlert("Ошибка", message)
                                }
                            }
                        }
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        },
        restore: {
            guard let controller = weakController else { return }
            let confirm = textAlertController(
                context: context,
                title: "Восстановить из бэкапа?",
                text: "Текущие данные аккаунтов будут заменены данными из бэкапа. "
                    + "Перед заменой создаётся защитный снимок. После подготовки "
                    + "потребуется перезапуск приложения.",
                actions: [
                    TextAlertAction(type: .genericAction, title: "Отмена", action: {}),
                    TextAlertAction(type: .defaultAction, title: "Восстановить", action: {
                        runBusy {
                            let result = AccountBackupManager.shared.prepareRestore()
                            DispatchQueue.main.async {
                                refresh()
                                switch result {
                                case .success:
                                    presentAlert("Бэкап подготовлен",
                                                 "Полностью закройте и перезапустите приложение, "
                                                 + "чтобы завершить восстановление.")
                                case let .failure(message):
                                    presentAlert("Ошибка", message)
                                }
                            }
                        }
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        },
        delete: {
            guard let controller = weakController else { return }
            let confirm = textAlertController(
                context: context,
                title: "Удалить бэкап?",
                text: "Зашифрованный бэкап и ключ из Keychain будут удалены. Действие необратимо.",
                actions: [
                    TextAlertAction(type: .genericAction, title: "Отмена", action: {}),
                    TextAlertAction(type: .destructiveAction, title: "Удалить", action: {
                        AccountBackupManager.shared.deleteBackup()
                        refresh()
                    })
                ]
            )
            controller.present(confirm, in: .window(.root))
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let entries = backupEntries(state: state, theme: presentationData.theme)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("Бэкап аккаунтов"),
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
