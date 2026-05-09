import SwiftUI

struct AorusGramSettingsView: View {
    // MARK: - State

    @State private var ghostMode        = AorusGramConfig.isEnabled(.ghostMode)
    @State private var deletedMessages  = AorusGramConfig.isEnabled(.deletedMessages)
    @State private var antiSpam         = AorusGramConfig.isEnabled(.antiSpam)
    @State private var downloadAccel    = AorusGramConfig.isEnabled(.downloadAccel)
    @State private var glassUI          = AorusGramConfig.isEnabled(.glassUI)
    @State private var voiceTranscript  = AorusGramConfig.isEnabled(.voiceTranscription)
    @State private var chatSummary      = AorusGramConfig.isEnabled(.chatSummary)
    @State private var translator       = AorusGramConfig.isEnabled(.translator)
    @State private var antiScreenshot   = AorusGramConfig.isEnabled(.antiScreenshot)
    @State private var secretPin        = AorusGramConfig.isEnabled(.secretPin)
    @State private var streaks          = AorusGramConfig.isEnabled(.streaks)
    @State private var siri             = AorusGramConfig.isEnabled(.siriShortcuts)
    @State private var autoReply        = AorusGramConfig.isEnabled(.autoReply)
    @State private var pinboard         = AorusGramConfig.isEnabled(.pinboard)

    @State private var showSpamKeywords = false
    @State private var showSecretPin    = false

    var body: some View {
        ZStack {
            AorusAnimatedBackground()

            ScrollView {
                VStack(spacing: 16) {
                    header
                    privacySection
                    aiSection
                    performanceSection
                    uiSection
                    extraSection
                    officialChannelButton
                    versionFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSpamKeywords) { SpamKeywordsView() }
        .sheet(isPresented: $showSecretPin)    { SecretPinSetupView() }
    }

    // MARK: - Header

    private var header: some View {
        GlassCard {
            HStack(spacing: 16) {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: "#FF6D00"), Color(hex: "#FF3D00")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(width: 56, height: 56)

                    Text("🔥")
                        .font(.system(size: 30))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("AorusGram")
                        .font(.system(size: 22, weight: .black))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "#FF6D00"), Color(hex: "#FF3D00")],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                    Text("v\(AorusGramConfig.version) · Telegram Enhanced")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(16)
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        settingsSection(title: "Приватность", icon: "lock.shield.fill", color: Color(hex: "#5C6BC0")) {
            GlassToggleRow(
                icon: "eye.slash.fill", title: "Режим призрака",
                subtitle: "Скрыть онлайн и прочтение",
                iconColor: Color(hex: "#5C6BC0"), isOn: $ghostMode
            )
            .onChange(of: ghostMode) { v in
                AorusGramConfig.setEnabled(.ghostMode, v)
                GhostModeManager.shared.toggle()
            }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "trash.slash.fill", title: "Удалённые сообщения",
                subtitle: "Сохранять до удаления",
                iconColor: Color(hex: "#EF5350"), isOn: $deletedMessages
            )
            .onChange(of: deletedMessages) { v in AorusGramConfig.setEnabled(.deletedMessages, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "camera.fill", title: "Защита от скриншотов",
                subtitle: "Фейк-экран при скриншоте приложения",
                iconColor: Color(hex: "#AB47BC"), isOn: $antiScreenshot
            )
            .onChange(of: antiScreenshot) { v in AorusGramConfig.setEnabled(.antiScreenshot, v) }

            Divider().opacity(0.15)

            HStack {
                GlassToggleRow(
                    icon: "lock.rectangle.stack.fill", title: "Секретный пин",
                    subtitle: "Другой код — другой аккаунт",
                    iconColor: Color(hex: "#26A69A"), isOn: $secretPin
                )
                .onChange(of: secretPin) { v in
                    AorusGramConfig.setEnabled(.secretPin, v)
                    if v { showSecretPin = true }
                }
            }
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        settingsSection(title: "AI Функции", icon: "sparkles", color: Color(hex: "#FF6D00")) {
            GlassToggleRow(
                icon: "waveform", title: "Транскрипция войсов",
                subtitle: "Текст под голосовым сообщением",
                iconColor: Color(hex: "#FF6D00"), isOn: $voiceTranscript
            )
            .onChange(of: voiceTranscript) { v in AorusGramConfig.setEnabled(.voiceTranscription, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "text.bubble.fill", title: "Саммари чата",
                subtitle: "AI сжимает переписку в 5 строк",
                iconColor: Color(hex: "#FF8F00"), isOn: $chatSummary
            )
            .onChange(of: chatSummary) { v in AorusGramConfig.setEnabled(.chatSummary, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "globe", title: "Переводчик",
                subtitle: "Перевод прямо в пузырьке",
                iconColor: Color(hex: "#42A5F5"), isOn: $translator
            )
            .onChange(of: translator) { v in AorusGramConfig.setEnabled(.translator, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "arrow.uturn.left.circle.fill", title: "Авто-ответчик",
                subtitle: "Отвечает пока ты занят",
                iconColor: Color(hex: "#66BB6A"), isOn: $autoReply
            )
            .onChange(of: autoReply) { v in AorusGramConfig.setEnabled(.autoReply, v) }
        }
    }

    // MARK: - Performance

    private var performanceSection: some View {
        settingsSection(title: "Производительность", icon: "bolt.fill", color: Color(hex: "#FDD835")) {
            GlassToggleRow(
                icon: "arrow.down.circle.fill", title: "Ускоритель загрузок",
                subtitle: "×2 скорость через параллельные соединения",
                iconColor: Color(hex: "#FDD835"), isOn: $downloadAccel
            )
            .onChange(of: downloadAccel) { v in AorusGramConfig.setEnabled(.downloadAccel, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "hand.raised.fill", title: "Анти-спам",
                subtitle: "Автоблок по ключевым словам",
                iconColor: Color(hex: "#EF5350"), isOn: $antiSpam
            )
            .onChange(of: antiSpam) { v in AorusGramConfig.setEnabled(.antiSpam, v) }

            if antiSpam {
                Button {
                    showSpamKeywords = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Настроить ключевые слова →")
                            .font(.system(size: 13))
                            .foregroundColor(Color(hex: "#EF5350"))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    // MARK: - UI

    private var uiSection: some View {
        settingsSection(title: "Интерфейс", icon: "paintbrush.fill", color: Color(hex: "#26C6DA")) {
            GlassToggleRow(
                icon: "rectangle.stack.fill", title: "Glass UI",
                subtitle: "Стеклянный интерфейс с анимациями",
                iconColor: Color(hex: "#26C6DA"), isOn: $glassUI
            )
            .onChange(of: glassUI) { v in AorusGramConfig.setEnabled(.glassUI, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "flame.fill", title: "Streak счётчик",
                subtitle: "Дни подряд общения с контактом",
                iconColor: Color(hex: "#FF7043"), isOn: $streaks
            )
            .onChange(of: streaks) { v in AorusGramConfig.setEnabled(.streaks, v) }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "pin.fill", title: "Pinboard",
                subtitle: "Доска важных сообщений из разных чатов",
                iconColor: Color(hex: "#FFA726"), isOn: $pinboard
            )
            .onChange(of: pinboard) { v in AorusGramConfig.setEnabled(.pinboard, v) }
        }
    }

    // MARK: - Extra

    private var extraSection: some View {
        settingsSection(title: "Дополнительно", icon: "gearshape.2.fill", color: .secondary) {
            GlassToggleRow(
                icon: "mic.fill", title: "Siri Shortcuts",
                subtitle: "Голосовые команды для Telegram",
                iconColor: Color(hex: "#9C27B0"), isOn: $siri
            )
            .onChange(of: siri) { v in
                AorusGramConfig.setEnabled(.siriShortcuts, v)
                if v { SiriShortcutsManager.shared.donateAllDefaults() }
            }
        }
    }

    // MARK: - Official Channel

    private var officialChannelButton: some View {
        Button {
            if let url = URL(string: AorusGramConfig.officialChannelURL) {
                UIApplication.shared.open(url)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        LinearGradient(
                            colors: [Color(hex: "#29B6F6"), Color(hex: "#0288D1")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: 44, height: 44)
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Официальный канал")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                        Text("@aorusgram · Обновления и новости")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var versionFooter: some View {
        Text("AorusGram \(AorusGramConfig.version) · Based on Telegram iOS")
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.6))
            .multilineTextAlignment(.center)
    }

    // MARK: - Helper

    @ViewBuilder
    private func settingsSection<Content: View>(
        title: String, icon: String, color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 4)

            GlassCard(cornerRadius: 16) {
                VStack(spacing: 0) { content() }
            }
        }
    }
}

// MARK: - Spam Keywords Sheet

struct SpamKeywordsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var keywords = AntiSpamManager.shared.keywords
    @State private var newKeyword = ""

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                List {
                    Section("Ключевые слова") {
                        ForEach(keywords, id: \.self) { kw in
                            Text(kw)
                        }
                        .onDelete { idx in
                            idx.forEach { AntiSpamManager.shared.removeKeyword(keywords[$0]) }
                            keywords = AntiSpamManager.shared.keywords
                        }

                        HStack {
                            TextField("Добавить слово...", text: $newKeyword)
                            Button("Добавить") {
                                AntiSpamManager.shared.addKeyword(newKeyword)
                                keywords = AntiSpamManager.shared.keywords
                                newKeyword = ""
                            }
                            .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Анти-спам фильтр")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Secret Pin Sheet

struct SecretPinSetupView: View {
    @Environment(\.dismiss) var dismiss
    @State private var realPin   = ""
    @State private var decoyPin  = ""

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                Form {
                    Section("Настройка двойного пин-кода") {
                        SecureField("Реальный пин", text: $realPin)
                        SecureField("Пин-приманка (фейк)", text: $decoyPin)
                    }
                    Section {
                        Text("При вводе реального пина — открываются все чаты. При вводе пина-приманки — показывается пустой/другой аккаунт.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Секретный пин")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        // Сохранить пины в Keychain
                        dismiss()
                    }
                    .disabled(realPin.count < 4 || decoyPin.count < 4)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }
}
