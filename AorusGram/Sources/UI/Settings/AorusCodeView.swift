import SwiftUI
import UIKit

struct AorusCodeView: View {
    @Environment(\.dismiss) var dismiss
    @State private var input       = ""
    @State private var resultMsg   = ""
    @State private var resultOK    = false
    @State private var isChecking  = false
    @State private var showResult  = false

    private let mgr = AorusCodeManager.shared

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                ScrollView {
                    VStack(spacing: 24) {
                        // Status card
                        if let code = mgr.activated, code.isValid {
                            activeCodeCard(code: code)
                        } else {
                            inactiveCard
                        }

                        // Input
                        GlassCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Активировать код", systemImage: "key.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(hex: "#FF6D00"))

                                TextField("AORUS-XXXX-XXXX-XXXX-XXXX", text: $input)
                                    .font(.system(size: 15, design: .monospaced))
                                    .autocapitalization(.allCharacters)
                                    .disableAutocorrection(true)
                                    .padding(10)
                                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                                if showResult {
                                    HStack {
                                        Image(systemName: resultOK ? "checkmark.seal.fill" : "xmark.seal.fill")
                                        Text(resultMsg)
                                            .font(.system(size: 13))
                                    }
                                    .foregroundColor(resultOK ? .green : .red)
                                    .transition(.opacity)
                                }

                                GlassButton(
                                    title: isChecking ? "Проверка..." : "Активировать",
                                    icon: "arrow.right.circle.fill",
                                    color: Color(hex: "#FF6D00")
                                ) { activate() }
                                .disabled(input.count < 10 || isChecking)
                            }
                            .padding(16)
                        }

                        // Feature matrix
                        tierFeaturesCard
                    }
                    .padding(16)
                }
            }
            .navigationTitle("AorusCode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    // MARK: - Active card

    private func activeCodeCard(code: AorusCodeManager.ActivatedCode) -> some View {
        GlassCard {
            VStack(spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(code.tier.emoji)
                            Text("AorusGram \(code.tier.displayName)")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color(hex: "#FF6D00"), Color(hex: "#FF3D00")],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                )
                        }
                        Text("Активирован")
                            .font(.system(size: 12))
                            .foregroundColor(.green)
                    }
                    Spacer()
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                }

                Divider().opacity(0.15)

                if let exp = code.expiresAt {
                    HStack {
                        Label("Истекает", systemImage: "calendar")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(exp, style: .date)
                            .font(.system(size: 13, weight: .semibold))
                    }
                } else {
                    HStack {
                        Label("Срок действия", systemImage: "infinity")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Бессрочно")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.green)
                    }
                }

                Text(code.code)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))

                Button(role: .destructive) {
                    mgr.deactivate()
                } label: {
                    Label("Деактивировать", systemImage: "trash")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    private var inactiveCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Нет активного кода")
                    .font(.system(size: 16, weight: .semibold))
                Text("Введите AorusCode чтобы получить доступ к Pro и Lifetime функциям")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        }
    }

    // MARK: - Tier features

    private var tierFeaturesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Уровни доступа", systemImage: "list.star")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: "#5C6BC0"))
                    .padding(.bottom, 4)

                tierRow(tier: .beta, features: ["Тестирование новых функций", "Ранний доступ"])
                Divider().opacity(0.15)
                tierRow(tier: .pro, features: ["Все Beta-функции", "AI-саммари без лимитов", "Ускоритель загрузок ×4"])
                Divider().opacity(0.15)
                tierRow(tier: .lifetime, features: ["Всё включено навсегда", "Приоритетная поддержка", "Ранний доступ к новым функциям"])
            }
            .padding(16)
        }
    }

    private func tierRow(tier: AorusCodeManager.Tier, features: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(tier.emoji) \(tier.displayName)")
                .font(.system(size: 14, weight: .bold))
            ForEach(features, id: \.self) { f in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.green)
                    Text(f)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Activation

    private func activate() {
        isChecking = true
        showResult = false

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            let result = mgr.activate(code: input)
            DispatchQueue.main.async {
                isChecking = false
                withAnimation {
                    switch result {
                    case .success(let code):
                        resultOK  = true
                        resultMsg = "\(code.tier.emoji) Активировано: AorusGram \(code.tier.displayName)"
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                    case .invalidFormat:
                        resultOK  = false
                        resultMsg = "Неверный формат кода"
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    case .invalidCode:
                        resultOK  = false
                        resultMsg = "Недействительный код"
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    case .expired:
                        resultOK  = false
                        resultMsg = "Код истёк"
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    case .alreadyActivated:
                        resultOK  = true
                        resultMsg = "Уже активировано"
                    case .deviceMismatch:
                        resultOK  = false
                        resultMsg = "Код привязан к другому устройству"
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                    }
                    showResult = true
                }
            }
        }
    }
}
