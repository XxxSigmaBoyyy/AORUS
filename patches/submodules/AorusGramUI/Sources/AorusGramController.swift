import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Sections

private enum AorusSection: Int32 {
    case privacy
    case ai
    case performance
    case ui
    case antiSpoof
    case aorusCode
    case channel
}

// MARK: - State

private struct AorusState: Equatable {
    var ghostMode: Bool
    var blockReadReceipts: Bool
    var hideTyping: Bool
    var saveDeletedMessages: Bool
    var antiScreenshot: Bool
    var voiceTranscription: Bool
    var chatSummary: Bool
    var translator: Bool
    var autoReply: Bool
    var downloadAccel: Bool
    var antiSpamEnabled: Bool
    var streaks: Bool
    var glassUI: Bool
    var siriShortcuts: Bool
    var antiSpoofDeleted: Bool
    var antiSpoofOnline: Bool
    var aorusCodeEnabled: Bool
}

// MARK: - Arguments

private final class AorusArguments {
    let set: (WritableKeyPath<AorusState, Bool>, Bool) -> Void
    let openChannel: () -> Void

    init(set: @escaping (WritableKeyPath<AorusState, Bool>, Bool) -> Void,
         openChannel: @escaping () -> Void) {
        self.set = set
        self.openChannel = openChannel
    }
}

// MARK: - Entries

private enum AorusEntry: ItemListNodeEntry {
    case privacyHeader(PresentationTheme, String)
    case ghostMode(PresentationTheme, String, Bool)
    case blockReadReceipts(PresentationTheme, String, Bool)
    case hideTyping(PresentationTheme, String, Bool)
    case saveDeletedMessages(PresentationTheme, String, Bool)
    case antiScreenshot(PresentationTheme, String, Bool)

    case aiHeader(PresentationTheme, String)
    case voiceTranscription(PresentationTheme, String, Bool)
    case chatSummary(PresentationTheme, String, Bool)
    case translator(PresentationTheme, String, Bool)
    case autoReply(PresentationTheme, String, Bool)

    case perfHeader(PresentationTheme, String)
    case downloadAccel(PresentationTheme, String, Bool)
    case antiSpam(PresentationTheme, String, Bool)
    case streaks(PresentationTheme, String, Bool)

    case uiHeader(PresentationTheme, String)
    case glassUI(PresentationTheme, String, Bool)
    case siriShortcuts(PresentationTheme, String, Bool)

    case antiSpoofHeader(PresentationTheme, String)
    case antiSpoofDeleted(PresentationTheme, String, Bool)
    case antiSpoofOnline(PresentationTheme, String, Bool)

    case aorusCodeHeader(PresentationTheme, String)
    case aorusCodeEnabled(PresentationTheme, String, Bool)

    case officialChannel(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .privacyHeader, .ghostMode, .blockReadReceipts, .hideTyping,
             .saveDeletedMessages, .antiScreenshot:
            return AorusSection.privacy.rawValue
        case .aiHeader, .voiceTranscription, .chatSummary, .translator, .autoReply:
            return AorusSection.ai.rawValue
        case .perfHeader, .downloadAccel, .antiSpam, .streaks:
            return AorusSection.performance.rawValue
        case .uiHeader, .glassUI, .siriShortcuts:
            return AorusSection.ui.rawValue
        case .antiSpoofHeader, .antiSpoofDeleted, .antiSpoofOnline:
            return AorusSection.antiSpoof.rawValue
        case .aorusCodeHeader, .aorusCodeEnabled:
            return AorusSection.aorusCode.rawValue
        case .officialChannel:
            return AorusSection.channel.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .privacyHeader:        return 0
        case .ghostMode:            return 1
        case .blockReadReceipts:    return 2
        case .hideTyping:           return 3
        case .saveDeletedMessages:  return 4
        case .antiScreenshot:       return 5
        case .aiHeader:             return 10
        case .voiceTranscription:   return 11
        case .chatSummary:          return 12
        case .translator:           return 13
        case .autoReply:            return 14
        case .perfHeader:           return 20
        case .downloadAccel:        return 21
        case .antiSpam:             return 22
        case .streaks:              return 23
        case .uiHeader:             return 30
        case .glassUI:              return 31
        case .siriShortcuts:        return 32
        case .antiSpoofHeader:      return 50
        case .antiSpoofDeleted:     return 51
        case .antiSpoofOnline:      return 52
        case .aorusCodeHeader:      return 60
        case .aorusCodeEnabled:     return 61
        case .officialChannel:      return 70
        }
    }

    static func < (lhs: AorusEntry, rhs: AorusEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: AorusEntry, rhs: AorusEntry) -> Bool {
        switch lhs {
        case let .privacyHeader(lt, ls):
            if case let .privacyHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .ghostMode(lt, ls, lv):
            if case let .ghostMode(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .blockReadReceipts(lt, ls, lv):
            if case let .blockReadReceipts(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .hideTyping(lt, ls, lv):
            if case let .hideTyping(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .saveDeletedMessages(lt, ls, lv):
            if case let .saveDeletedMessages(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiScreenshot(lt, ls, lv):
            if case let .antiScreenshot(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .aiHeader(lt, ls):
            if case let .aiHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .voiceTranscription(lt, ls, lv):
            if case let .voiceTranscription(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .chatSummary(lt, ls, lv):
            if case let .chatSummary(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .translator(lt, ls, lv):
            if case let .translator(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .autoReply(lt, ls, lv):
            if case let .autoReply(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .perfHeader(lt, ls):
            if case let .perfHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .downloadAccel(lt, ls, lv):
            if case let .downloadAccel(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpam(lt, ls, lv):
            if case let .antiSpam(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .streaks(lt, ls, lv):
            if case let .streaks(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .uiHeader(lt, ls):
            if case let .uiHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .glassUI(lt, ls, lv):
            if case let .glassUI(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .siriShortcuts(lt, ls, lv):
            if case let .siriShortcuts(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpoofHeader(lt, ls):
            if case let .antiSpoofHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .antiSpoofDeleted(lt, ls, lv):
            if case let .antiSpoofDeleted(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .antiSpoofOnline(lt, ls, lv):
            if case let .antiSpoofOnline(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .aorusCodeHeader(lt, ls):
            if case let .aorusCodeHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .aorusCodeEnabled(lt, ls, lv):
            if case let .aorusCodeEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .officialChannel(lt, ls):
            if case let .officialChannel(rt, rs) = rhs { return lt === rt && ls == rs }
        }
        return false
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! AorusArguments
        switch self {
        case let .privacyHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .ghostMode(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.ghostMode, $0) })
        case let .blockReadReceipts(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.blockReadReceipts, $0) })
        case let .hideTyping(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.hideTyping, $0) })
        case let .saveDeletedMessages(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.saveDeletedMessages, $0) })
        case let .antiScreenshot(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiScreenshot, $0) })
        case let .aiHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .voiceTranscription(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.voiceTranscription, $0) })
        case let .chatSummary(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.chatSummary, $0) })
        case let .translator(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.translator, $0) })
        case let .autoReply(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.autoReply, $0) })
        case let .perfHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .downloadAccel(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.downloadAccel, $0) })
        case let .antiSpam(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpamEnabled, $0) })
        case let .streaks(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.streaks, $0) })
        case let .uiHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .glassUI(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.glassUI, $0) })
        case let .siriShortcuts(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.siriShortcuts, $0) })
        case let .antiSpoofHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .antiSpoofDeleted(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpoofDeleted, $0) })
        case let .antiSpoofOnline(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.antiSpoofOnline, $0) })
        case let .aorusCodeHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .aorusCodeEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.aorusCodeEnabled, $0) })
        case let .officialChannel(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openChannel)
        }
    }
}

// MARK: - Entries builder

private func aorusEntries(state: AorusState, theme: PresentationTheme) -> [AorusEntry] {
    return [
        .privacyHeader(theme, "🔒 ПРИВАТНОСТЬ"),
        .ghostMode(theme, "Режим призрака", state.ghostMode),
        .blockReadReceipts(theme, "Блокировать прочтение", state.blockReadReceipts),
        .hideTyping(theme, "Скрыть «печатает...»", state.hideTyping),
        .saveDeletedMessages(theme, "Удалённые сообщения", state.saveDeletedMessages),
        .antiScreenshot(theme, "Защита от скриншотов", state.antiScreenshot),

        .aiHeader(theme, "✨ AI ФУНКЦИИ"),
        .voiceTranscription(theme, "Транскрипция войсов", state.voiceTranscription),
        .chatSummary(theme, "Саммари чата", state.chatSummary),
        .translator(theme, "Переводчик", state.translator),
        .autoReply(theme, "Авто-ответчик", state.autoReply),

        .perfHeader(theme, "⚡️ ПРОИЗВОДИТЕЛЬНОСТЬ"),
        .downloadAccel(theme, "Ускоритель загрузок", state.downloadAccel),
        .antiSpam(theme, "Анти-спам", state.antiSpamEnabled),
        .streaks(theme, "Streak счётчик 🔥", state.streaks),

        .uiHeader(theme, "🎨 ИНТЕРФЕЙС"),
        .glassUI(theme, "Glass UI", state.glassUI),
        .siriShortcuts(theme, "Siri Shortcuts", state.siriShortcuts),

        .antiSpoofHeader(theme, "🕵️ АНТИ-СПУФ"),
        .antiSpoofDeleted(theme, "Анти-спуф удалёнок", state.antiSpoofDeleted),
        .antiSpoofOnline(theme, "Анти-спуф онлайна", state.antiSpoofOnline),

        .aorusCodeHeader(theme, "🔐 AORUS CODE"),
        .aorusCodeEnabled(theme, "AorusCode", state.aorusCodeEnabled),

        .officialChannel(theme, "📢 Официальный канал @aorusgram"),
    ]
}

// MARK: - Public factory

public func aorusGramController(context: AccountContext) -> ViewController {
    let mgr   = AorusGramManager.shared
    let spoof = AntiSpoofManager.shared
    let stealth = AorusStealthCodec.shared

    let initialState = AorusState(
        ghostMode:          mgr.ghostMode,
        blockReadReceipts:  mgr.blockReadReceipts,
        hideTyping:         mgr.hideTyping,
        saveDeletedMessages: mgr.saveDeletedMessages,
        antiScreenshot:     mgr.antiScreenshot,
        voiceTranscription: mgr.voiceTranscription,
        chatSummary:        mgr.chatSummary,
        translator:         mgr.translator,
        autoReply:          mgr.autoReply,
        downloadAccel:      mgr.downloadAccel,
        antiSpamEnabled:    mgr.antiSpamEnabled,
        streaks:            mgr.streaks,
        glassUI:            mgr.glassUI,
        siriShortcuts:      mgr.siriShortcuts,
        antiSpoofDeleted:   spoof.antiSpoofDeleted,
        antiSpoofOnline:    spoof.antiSpoofOnline,
        aorusCodeEnabled:   stealth.isEnabled
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue   = Atomic(value: initialState)

    let updateState: ((AorusState) -> AorusState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = AorusArguments(
        set: { keyPath, value in
            updateState { current in
                var next = current
                next[keyPath: keyPath] = value
                return next
            }
            // Persist to managers based on which key changed
            let s = stateValue.with { $0 }
            mgr.ghostMode           = s.ghostMode
            mgr.blockReadReceipts   = s.blockReadReceipts
            mgr.hideTyping          = s.hideTyping
            mgr.saveDeletedMessages = s.saveDeletedMessages
            mgr.antiScreenshot      = s.antiScreenshot
            mgr.voiceTranscription  = s.voiceTranscription
            mgr.chatSummary         = s.chatSummary
            mgr.translator          = s.translator
            mgr.autoReply           = s.autoReply
            mgr.downloadAccel       = s.downloadAccel
            mgr.antiSpamEnabled     = s.antiSpamEnabled
            mgr.streaks             = s.streaks
            mgr.glassUI             = s.glassUI
            mgr.siriShortcuts       = s.siriShortcuts
            spoof.antiSpoofDeleted  = s.antiSpoofDeleted
            spoof.antiSpoofOnline   = s.antiSpoofOnline
            stealth.isEnabled       = s.aorusCodeEnabled
        },
        openChannel: {
            context.sharedContext.applicationBindings.openUrl("https://t.me/aorusgram")
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let entries = aorusEntries(state: state, theme: presentationData.theme)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("🔥 AorusGram"),
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

    return ItemListController(context: context, state: signal)
}
