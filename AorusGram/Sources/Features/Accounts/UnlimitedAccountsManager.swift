import Foundation
import SwiftUI

// Менеджер безлимитных аккаунтов.
// TelegramCore поддерживает до 4 аккаунтов из коробки.
// Снимаем ограничение патчем AccountManager.maxAccountCount
// и добавляем быстрое переключение свайпом.
final class UnlimitedAccountsManager {
    static let shared = UnlimitedAccountsManager()
    private init() { load() }

    private let defaultsKey = "aorusgram_accounts"

    private(set) var accounts: [AorusAccount] = []
    private(set) var activeAccountId: String?

    // MARK: - Load / Save

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        accounts        = saved.accounts
        activeAccountId = saved.activeAccountId
    }

    private func save() {
        let state = SavedState(accounts: accounts, activeAccountId: activeAccountId)
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: defaultsKey)
    }

    // MARK: - Account Management

    var activeAccount: AorusAccount? {
        accounts.first { $0.id == activeAccountId }
    }

    func addAccount(_ account: AorusAccount) {
        guard !accounts.contains(where: { $0.id == account.id }) else { return }
        accounts.append(account)
        if activeAccountId == nil { activeAccountId = account.id }
        save()
        NotificationCenter.default.post(name: .accountsChanged, object: nil)
    }

    func removeAccount(id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountId == id {
            activeAccountId = accounts.first?.id
        }
        save()
        NotificationCenter.default.post(name: .accountsChanged, object: nil)
    }

    func switchToAccount(id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountId = id
        save()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        NotificationCenter.default.post(
            name: .accountSwitched,
            object: nil,
            userInfo: ["accountId": id]
        )
    }

    // Свайп влево/вправо для переключения аккаунтов
    func switchToNext() {
        guard let current = activeAccountId,
              let idx = accounts.firstIndex(where: { $0.id == current }) else { return }
        let next = (idx + 1) % accounts.count
        switchToAccount(id: accounts[next].id)
    }

    func switchToPrevious() {
        guard let current = activeAccountId,
              let idx = accounts.firstIndex(where: { $0.id == current }) else { return }
        let prev = (idx - 1 + accounts.count) % accounts.count
        switchToAccount(id: accounts[prev].id)
    }

    // MARK: - Patch TelegramCore account limit

    static func removeAccountLimit() {
        // Патч AccountManager.maxAccountCount = Int.max
        guard
            let cls      = NSClassFromString("AccountManager"),
            let original = class_getClassMethod(cls, NSSelectorFromString("maximumNumberOfAccounts")),
            let patched  = class_getClassMethod(UnlimitedAccountsManager.self, #selector(ao_maxAccounts))
        else { return }
        method_exchangeImplementations(original, patched)
    }

    @objc private class func ao_maxAccounts() -> Int { return 100 }

    // MARK: - Models

    private struct SavedState: Codable {
        var accounts: [AorusAccount]
        var activeAccountId: String?
    }
}

struct AorusAccount: Identifiable, Codable, Equatable {
    let id: String
    var phoneNumber: String
    var displayName: String
    var username: String?
    var avatarColor: String   // hex
    var unreadCount: Int
    var isPremium: Bool

    var initials: String {
        let parts = displayName.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? ""
        let last  = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }
}

// MARK: - Account Switcher SwiftUI

struct AccountSwitcherOverlay: View {
    @ObservedObject private var mgr = AccountsObservable.shared
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(mgr.accounts) { account in
                accountBadge(account)
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            UnlimitedAccountsManager.shared.switchToAccount(id: account.id)
                        }
                    }
            }

            addButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .gesture(
            DragGesture()
                .onEnded { v in
                    if v.translation.width < -50 { UnlimitedAccountsManager.shared.switchToNext() }
                    if v.translation.width >  50 { UnlimitedAccountsManager.shared.switchToPrevious() }
                }
        )
    }

    @ViewBuilder
    private func accountBadge(_ account: AorusAccount) -> some View {
        let isActive = account.id == mgr.activeAccountId
        ZStack {
            Circle()
                .fill(Color(hex: account.avatarColor))
                .frame(width: 36, height: 36)
                .overlay(
                    Circle().stroke(Color.white, lineWidth: isActive ? 2 : 0)
                )
            Text(account.initials)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            if account.unreadCount > 0 {
                Text("\(min(account.unreadCount, 99))")
                    .font(.system(size: 9, weight: .black))
                    .foregroundColor(.white)
                    .padding(3)
                    .background(Color.red)
                    .clipShape(Capsule())
                    .offset(x: 12, y: -12)
            }
        }
        .scaleEffect(isActive ? 1.1 : 0.9)
        .animation(.spring(response: 0.3), value: isActive)
        .padding(.horizontal, 4)
    }

    private var addButton: some View {
        Image(systemName: "plus.circle.fill")
            .font(.system(size: 26))
            .foregroundColor(.secondary)
            .padding(.horizontal, 4)
    }
}

final class AccountsObservable: ObservableObject {
    static let shared = AccountsObservable()
    @Published var accounts: [AorusAccount]       = UnlimitedAccountsManager.shared.accounts
    @Published var activeAccountId: String?        = UnlimitedAccountsManager.shared.activeAccountId

    private var cancellables: [NSObjectProtocol] = []

    private init() {
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: .accountsChanged, object: nil, queue: .main
            ) { [weak self] _ in
                self?.accounts        = UnlimitedAccountsManager.shared.accounts
                self?.activeAccountId = UnlimitedAccountsManager.shared.activeAccountId
            }
        )
        cancellables.append(
            NotificationCenter.default.addObserver(
                forName: .accountSwitched, object: nil, queue: .main
            ) { [weak self] _ in
                self?.activeAccountId = UnlimitedAccountsManager.shared.activeAccountId
            }
        )
    }
}

extension Notification.Name {
    static let accountsChanged = Notification.Name("aorusgram_accounts_changed")
    static let accountSwitched = Notification.Name("aorusgram_account_switched")
}
