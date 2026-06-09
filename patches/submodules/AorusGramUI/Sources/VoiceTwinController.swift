import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

// MARK: - Sections

private enum VTSection: Int32 {
    case toggle
    case presets
}

// MARK: - State

private struct VTState: Equatable {
    var enabled: Bool
    var preset: String
}

// MARK: - Arguments

private final class VTArguments {
    let setEnabled: (Bool) -> Void
    let selectPreset: (String) -> Void

    init(setEnabled: @escaping (Bool) -> Void, selectPreset: @escaping (String) -> Void) {
        self.setEnabled = setEnabled
        self.selectPreset = selectPreset
    }
}

// MARK: - Entries

private enum VTEntry: ItemListNodeEntry {
    case toggle(PresentationTheme, String, Bool)
    case toggleFooter(PresentationTheme, String)
    case presetsHeader(PresentationTheme, String)
    case preset(PresentationTheme, Int, String, String, Bool)   // theme, order, key, title, selected

    var section: ItemListSectionId {
        switch self {
        case .toggle, .toggleFooter:  return VTSection.toggle.rawValue
        case .presetsHeader, .preset: return VTSection.presets.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .toggle:        return 0
        case .toggleFooter:  return 1
        case .presetsHeader: return 2
        case let .preset(_, order, _, _, _): return 10 + Int32(order)
        }
    }

    static func < (lhs: VTEntry, rhs: VTEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: VTEntry, rhs: VTEntry) -> Bool {
        switch lhs {
        case let .toggle(lt, ls, lv):
            if case let .toggle(rt, rs, rv) = rhs { return lt === rt && ls == rs && lv == rv }
            return false
        case let .toggleFooter(lt, ls):
            if case let .toggleFooter(rt, rs) = rhs { return lt === rt && ls == rs }
            return false
        case let .presetsHeader(lt, ls):
            if case let .presetsHeader(rt, rs) = rhs { return lt === rt && ls == rs }
            return false
        case let .preset(lt, lo, lk, ls, lsel):
            if case let .preset(rt, ro, rk, rs, rsel) = rhs {
                return lt === rt && lo == ro && lk == rk && ls == rs && lsel == rsel
            }
            return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let args = arguments as! VTArguments
        let section = self.section
        switch self {
        case let .toggle(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, title: title, value: value, sectionId: section, style: .blocks, updated: { args.setEnabled($0) })
        case let .toggleFooter(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section)
        case let .presetsHeader(_, text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: section)
        case let .preset(_, _, key, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, title: title, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: section, action: { args.selectPreset(key) })
        }
    }
}

// MARK: - Entries builder

private func voiceTwinEntries(state: VTState, theme: PresentationTheme, l10n: AorusL10n) -> [VTEntry] {
    var entries: [VTEntry] = []
    entries.append(.toggle(theme, l10n.voiceTwin, state.enabled))
    entries.append(.toggleFooter(theme, l10n.voiceTwinFooter))

    if state.enabled {
        entries.append(.presetsHeader(theme, l10n.voiceTwinVoiceHeader))
        let presets: [(String, String)] = [
            ("anonymous", l10n.voiceAnonymous),
            ("male",      l10n.voiceMale),
            ("female",    l10n.voiceFemale),
            ("robot",     l10n.voiceRobot),
            ("high",      l10n.voiceHigh),
        ]
        for (i, p) in presets.enumerated() {
            entries.append(.preset(theme, i, p.0, p.1, state.preset == p.0))
        }
    }
    return entries
}

// MARK: - Public factory

public func voiceTwinController(context: AccountContext) -> ViewController {
    let mgr = AorusGramManager.shared
    let initialState = VTState(enabled: mgr.voiceTwinEnabled, preset: mgr.voiceTwinPreset)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)

    let updateState: ((VTState) -> VTState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }

    let arguments = VTArguments(
        setEnabled: { value in
            AorusGramManager.shared.voiceTwinEnabled = value
            updateState { s in var n = s; n.enabled = value; return n }
        },
        selectPreset: { key in
            AorusGramManager.shared.voiceTwinPreset = key
            updateState { s in var n = s; n.preset = key; return n }
        }
    )

    let signal = statePromise.get()
        |> deliverOnMainQueue
        |> map { state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let l10n = AorusL10n(presentationData.strings.baseLanguageCode)
            let entries = voiceTwinEntries(state: state, theme: presentationData.theme, l10n: l10n)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(l10n.voiceTwin),
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
