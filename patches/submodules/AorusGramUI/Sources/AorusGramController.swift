import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
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
    case deviceSpoof
    case bypass
    case antiSpoof
    case accountBackup
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
    var spoofedDeviceName: String?
    var bypassSavePaid: Bool
    var bypassSaveViewOnce: Bool
    var bypassStoryDownload: Bool
}

// MARK: - Arguments

private final class AorusArguments {
    let set: (WritableKeyPath<AorusState, Bool>, Bool) -> Void
    let openChannel: () -> Void
    let clearCache: () -> Void
    let openAccountBackup: () -> Void
    let openDeviceSpoof: () -> Void

    init(set: @escaping (WritableKeyPath<AorusState, Bool>, Bool) -> Void,
         openChannel: @escaping () -> Void,
         clearCache: @escaping () -> Void,
         openAccountBackup: @escaping () -> Void,
         openDeviceSpoof: @escaping () -> Void) {
        self.set = set
        self.openChannel = openChannel
        self.clearCache = clearCache
        self.openAccountBackup = openAccountBackup
        self.openDeviceSpoof = openDeviceSpoof
    }
}

// MARK: - Entries

private enum AorusEntry: ItemListNodeEntry {
    case privacyHeader(PresentationTheme, String)
    case ghostMode(PresentationTheme, String, Bool)
    case saveDeletedMessages(PresentationTheme, String, Bool)
    case clearDeletedCache(PresentationTheme, String)
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

    case accountBackupHeader(PresentationTheme, String)
    case accountBackup(PresentationTheme, String)

    case aorusCodeHeader(PresentationTheme, String)
    case aorusCodeEnabled(PresentationTheme, String, Bool)

    case deviceSpoofHeader(PresentationTheme, String)
    case deviceSpoof(PresentationTheme, String, String)

    case bypassHeader(PresentationTheme, String)
    case bypassSavePaid(PresentationTheme, String, Bool)
    case bypassSaveViewOnce(PresentationTheme, String, Bool)
    case bypassStoryDownload(PresentationTheme, String, Bool)

    case officialChannel(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .privacyHeader, .ghostMode, .saveDeletedMessages, .clearDeletedCache, .antiScreenshot:
            return AorusSection.privacy.rawValue
        case .aiHeader, .voiceTranscription, .chatSummary, .translator, .autoReply:
            return AorusSection.ai.rawValue
        case .perfHeader, .downloadAccel, .antiSpam, .streaks:
            return AorusSection.performance.rawValue
        case .uiHeader, .glassUI, .siriShortcuts:
            return AorusSection.ui.rawValue
        case .deviceSpoofHeader, .deviceSpoof:
            return AorusSection.deviceSpoof.rawValue
        case .bypassHeader, .bypassSavePaid, .bypassSaveViewOnce, .bypassStoryDownload:
            return AorusSection.bypass.rawValue
        case .antiSpoofHeader, .antiSpoofDeleted, .antiSpoofOnline:
            return AorusSection.antiSpoof.rawValue
        case .accountBackupHeader, .accountBackup:
            return AorusSection.accountBackup.rawValue
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
        case .saveDeletedMessages:  return 4
        case .clearDeletedCache:    return 5
        case .antiScreenshot:       return 6
        case .aiHeader:             return 10
        case .voiceTranscription:   return 11
        case .chatSummary:          return 13
        case .translator:           return 14
        case .autoReply:            return 16
        case .perfHeader:           return 20
        case .downloadAccel:        return 21
        case .antiSpam:             return 22
        case .streaks:              return 23
        case .uiHeader:             return 30
        case .glassUI:              return 31
        case .siriShortcuts:        return 32
        case .deviceSpoofHeader:    return 35
        case .deviceSpoof:          return 36
        case .bypassHeader:         return 40
        case .bypassSavePaid:       return 41
        case .bypassSaveViewOnce:   return 42
        case .bypassStoryDownload:  return 43
        case .antiSpoofHeader:      return 50
        case .antiSpoofDeleted:     return 51
        case .antiSpoofOnline:      return 52
        case .accountBackupHeader:  return 55
        case .accountBackup:        return 56
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
        case let .saveDeletedMessages(lt, ls, lv):
            if case let .saveDeletedMessages(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .clearDeletedCache(lt, ls):
            if case let .clearDeletedCache(rt, rs) = rhs { return lt === rt && ls == rs }
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
        case let .accountBackupHeader(lt, ls):
            if case let .accountBackupHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .accountBackup(lt, ls):
            if case let .accountBackup(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .aorusCodeHeader(lt, ls):
            if case let .aorusCodeHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .aorusCodeEnabled(lt, ls, lv):
            if case let .aorusCodeEnabled(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .deviceSpoofHeader(lt, ls):
            if case let .deviceSpoofHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .deviceSpoof(lt, ls, lv):
            if case let .deviceSpoof(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassHeader(lt, ls):
            if case let .bypassHeader(rt, rs) = rhs { return lt === rt && ls == rs }
        case let .bypassSavePaid(lt, ls, lv):
            if case let .bypassSavePaid(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassSaveViewOnce(lt, ls, lv):
            if case let .bypassSaveViewOnce(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
        case let .bypassStoryDownload(lt, ls, lv):
            if case let .bypassStoryDownload(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
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
        case let .saveDeletedMessages(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.saveDeletedMessages, $0) })
        case let .clearDeletedCache(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .destructive, alignment: .natural, sectionId: section, style: .blocks, action: args.clearCache)
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
        case let .accountBackupHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .accountBackup(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: "", sectionId: section, style: .blocks, action: args.openAccountBackup)
        case let .aorusCodeHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .aorusCodeEnabled(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.aorusCodeEnabled, $0) })
        case let .deviceSpoofHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .deviceSpoof(_, title, label):
            return ItemListDisclosureItem(presentationData: presentationData, title: title, label: label, sectionId: section, style: .blocks, action: args.openDeviceSpoof)
        case let .bypassHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .bypassSavePaid(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassSavePaid, $0) })
        case let .bypassSaveViewOnce(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassSaveViewOnce, $0) })
        case let .bypassStoryDownload(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.set(\.bypassStoryDownload, $0) })
        case let .officialChannel(_, title):
            return ItemListActionItem(presentationData: presentationData, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: args.openChannel)
        }
    }
}

// MARK: - Entries builder

private func aorusEntries(state: AorusState, theme: PresentationTheme, l10n: AorusL10n) -> [AorusEntry] {
    // Privacy section: exactly three rows.
    //   1. Ghost Mode — combined toggle that hides online + typing + read receipts
    //      (the per-feature sub-flags blockReadReceipts/hideTyping are still in state
    //       but no longer surfaced; source patches gate on aorusgram_ghost_mode only).
    //   2. Deleted Messages — preserves incoming deletes/edits inline in chat.
    //   3. Hide Screen While Recording — renamed from the ambiguous «Screenshot Protection».
    // A small destructive 'Clear Deleted Cache' action sits between (2) and (3) and
    // wipes preserved postbox rows accumulated by the source patches.
    // All visible strings are localized via AorusL10n (RU/EN, follows Telegram language).
    return [
        .privacyHeader(theme, l10n.privacyHeader),
        .ghostMode(theme, l10n.ghostMode, state.ghostMode),
        .saveDeletedMessages(theme, l10n.deletedMessages, state.saveDeletedMessages),
        .clearDeletedCache(theme, l10n.clearDeletedCache),
        .antiScreenshot(theme, l10n.antiScreenshot, state.antiScreenshot),

        .aiHeader(theme, l10n.aiHeader),
        .voiceTranscription(theme, l10n.voiceTranscription, state.voiceTranscription),
        .chatSummary(theme, l10n.chatSummary, state.chatSummary),
        .translator(theme, l10n.translator, state.translator),
        .autoReply(theme, l10n.autoReply, state.autoReply),

        .perfHeader(theme, l10n.perfHeader),
        .downloadAccel(theme, l10n.downloadAccel, state.downloadAccel),
        .antiSpam(theme, l10n.antiSpam, state.antiSpamEnabled),
        .streaks(theme, l10n.streaks, state.streaks),

        .uiHeader(theme, l10n.uiHeader),
        .glassUI(theme, l10n.glassUI, state.glassUI),
        .siriShortcuts(theme, l10n.siriShortcuts, state.siriShortcuts),

        .deviceSpoofHeader(theme, l10n.deviceSpoofHeader),
        .deviceSpoof(theme, l10n.deviceSpoof, state.spoofedDeviceName ?? l10n.deviceSpoofOff),

        .bypassHeader(theme, l10n.bypassHeader),
        .bypassSavePaid(theme, l10n.bypassSavePaid, state.bypassSavePaid),
        .bypassSaveViewOnce(theme, l10n.bypassSaveViewOnce, state.bypassSaveViewOnce),
        .bypassStoryDownload(theme, l10n.bypassStoryDownload, state.bypassStoryDownload),

        .antiSpoofHeader(theme, l10n.antiSpoofHeader),
        .antiSpoofDeleted(theme, l10n.antiSpoofDeleted, state.antiSpoofDeleted),
        .antiSpoofOnline(theme, l10n.antiSpoofOnline, state.antiSpoofOnline),

        .accountBackupHeader(theme, l10n.accountBackupHeader),
        .accountBackup(theme, l10n.accountBackup),

        .aorusCodeHeader(theme, l10n.aorusCodeHeader),
        .aorusCodeEnabled(theme, l10n.aorusCode, state.aorusCodeEnabled),

        .officialChannel(theme, l10n.officialChannel),
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
        aorusCodeEnabled:   stealth.isEnabled,
        spoofedDeviceName:  UserDefaults.standard.string(forKey: "aorusgram_spoofed_device"),
        bypassSavePaid:     UserDefaults.standard.object(forKey: "aorusgram_bypass_save_paid") as? Bool ?? true,
        bypassSaveViewOnce: UserDefaults.standard.object(forKey: "aorusgram_bypass_view_once") as? Bool ?? true,
        bypassStoryDownload: UserDefaults.standard.object(forKey: "aorusgram_bypass_story_dl") as? Bool ?? true
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue   = Atomic(value: initialState)

    let updateState: ((AorusState) -> AorusState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    // Weak reference so openChannel can navigate using the controller's nav stack
    weak var weakController: ItemListController?

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
            UserDefaults.standard.set(s.bypassSavePaid,      forKey: "aorusgram_bypass_save_paid")
            UserDefaults.standard.set(s.bypassSaveViewOnce,  forKey: "aorusgram_bypass_view_once")
            UserDefaults.standard.set(s.bypassStoryDownload, forKey: "aorusgram_bypass_story_dl")
        },
        openChannel: {
            // Resolve @aorusgram and navigate to the channel inside AorusGram.
            // `weakController` is referenced directly (no capture list) so the
            // closure reads the value assigned after it is created — capturing
            // `[weak weakController]` would freeze the nil it holds right now.
            // Browser fallback only if the nav stack is genuinely unavailable.
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                context.sharedContext.applicationBindings.openUrl("https://t.me/aorusgram")
                return
            }
            let _ = (context.engine.peers.resolvePeerByName(name: "aorusgram", referrer: nil)
            |> deliverOnMainQueue).start(next: { result in
                guard case let .result(peer) = result, let peer = peer else { return }
                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(
                    navigationController: navigationController,
                    context: context,
                    chatLocation: .peer(peer)
                ))
            })
        },
        clearCache: {
            let stored = (UserDefaults.standard.array(forKey: "aorusgram_preserved_msgs") as? [[String: Int64]]) ?? []
            guard !stored.isEmpty else { return }
            let ids: [MessageId] = stored.compactMap { entry in
                guard let p = entry["peerId"], let m = entry["msgId"], let ns = entry["namespace"] else { return nil }
                return MessageId(peerId: PeerId(p), namespace: Int32(ns), id: Int32(m))
            }
            let _ = (context.account.postbox.transaction { transaction -> Void in
                transaction.deleteMessages(ids, forEachMedia: { _ in })
            } |> deliverOnMainQueue).start(completed: {
                UserDefaults.standard.removeObject(forKey: "aorusgram_preserved_msgs")
            })
        },
        openAccountBackup: {
            guard let controller = weakController,
                  let navigationController = controller.navigationController as? NavigationController else {
                return
            }
            navigationController.pushViewController(accountBackupController(context: context))
        },
        openDeviceSpoof: {
            guard let controller = weakController else { return }
            let isRu = AorusLang.current == .ru
            let title = isRu ? "Выбери устройство" : "Select Device"
            let devices: [(String, String?)] = [
                (isRu ? "Выкл. (реальный девайс)" : "Off (real device)", nil),
                ("iPhone 16 Pro Max",    "iPhone 16 Pro Max"),
                ("iPhone 16 Pro",        "iPhone 16 Pro"),
                ("iPhone 16 Plus",       "iPhone 16 Plus"),
                ("iPhone 16",            "iPhone 16"),
                ("iPhone 15 Pro Max",    "iPhone 15 Pro Max"),
                ("iPhone 15 Pro",        "iPhone 15 Pro"),
                ("iPhone 15 Plus",       "iPhone 15 Plus"),
                ("iPhone 15",            "iPhone 15"),
                ("iPhone 14 Pro Max",    "iPhone 14 Pro Max"),
                ("iPhone 14 Pro",        "iPhone 14 Pro"),
                ("iPhone 13 Pro Max",    "iPhone 13 Pro Max"),
                ("iPhone 12 Pro Max",    "iPhone 12 Pro Max"),
                ("iPhone SE (3rd gen)",  "iPhone SE (3rd gen)"),
                ("iPad Pro 12.9\"",      "iPad Pro 12.9"),
            ]
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
            for (label, value) in devices {
                alert.addAction(UIAlertAction(title: label, style: .default) { _ in
                    if let value = value {
                        UserDefaults.standard.set(value, forKey: "aorusgram_spoofed_device")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "aorusgram_spoofed_device")
                    }
                    updateState { s in var n = s; n.spoofedDeviceName = value; return n }
                })
            }
            alert.addAction(UIAlertAction(title: isRu ? "Отмена" : "Cancel", style: .cancel))
            if let popover = alert.popoverPresentationController, let view = controller.view {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            controller.present(alert, animated: true)
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
            let entries = aorusEntries(state: state, theme: presentationData.theme, l10n: l10n)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("AorusGram"),
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
