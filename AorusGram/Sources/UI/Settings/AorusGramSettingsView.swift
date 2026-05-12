import SwiftUI

struct AorusGramSettingsView: View {
    // MARK: - State

    @State private var ghostMode       = AorusGramConfig.isEnabled(.ghostMode)
    @State private var deletedMessages = AorusGramConfig.isEnabled(.deletedMessages)
    @State private var antiSpam        = AorusGramConfig.isEnabled(.antiSpam)
    @State private var downloadAccel   = AorusGramConfig.isEnabled(.downloadAccel)
    @State private var glassUI         = AorusGramConfig.isEnabled(.glassUI)
    @State private var voiceTranscript = AorusGramConfig.isEnabled(.voiceTranscription)
    @State private var chatSummary     = AorusGramConfig.isEnabled(.chatSummary)
    @State private var translator      = AorusGramConfig.isEnabled(.translator)
    @State private var antiScreenshot  = AorusGramConfig.isEnabled(.antiScreenshot)
    @State private var secretPin       = AorusGramConfig.isEnabled(.secretPin)
    @State private var streaks         = AorusGramConfig.isEnabled(.streaks)
    @State private var siri            = AorusGramConfig.isEnabled(.siriShortcuts)
    @State private var autoReply       = AorusGramConfig.isEnabled(.autoReply)
    @State private var pinboard        = AorusGramConfig.isEnabled(.pinboard)

    @State private var showSpamKeywords  = false
    @State private var showSecretPin     = false
    @State private var showAutoReply     = false
    @State private var showPinboard      = false
    @State private var showDeletedAll    = false
    @State private var showAorusCode     = false

    @State private var deletedCount = 0

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
                    aorusCodeButton
                    officialChannelButton
                    versionFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { deletedCount = DeletedMessagesCache.shared.allDeletedCount() }
        .sheet(isPresented: $showSpamKeywords) { SpamKeywordsView() }
        .sheet(isPresented: $showSecretPin)    { SecretPinSetupView() }
        .sheet(isPresented: $showAutoReply)    { AutoReplySettingsView() }
        .sheet(isPresented: $showPinboard)     {
            NavigationView { PinboardView() }
        }
        .sheet(isPresented: $showDeletedAll) {
            NavigationView {
                DeletedMessagesView(peerId: 0, peerName: "Все чаты")
            }
        }
        .sheet(isPresented: $showAorusCode) { AorusCodeView() }
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
                    Text("🔥").font(.system(size: 30))
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
                subtitle: "Скрыть онлайн, прочтение и «печатает...»",
                iconColor: Color(hex: "#5C6BC0"), isOn: $ghostMode
            )
            .onChange(of: ghostMode) { v in
                AorusGramConfig.setEnabled(.ghostMode, v)
                GhostModeManager.shared.setEnabled(v)
            }

            Divider().opacity(0.15)

            VStack(spacing: 0) {
                GlassToggleRow(
                    icon: "trash.slash.fill", title: "Удалённые сообщения",
                    subtitle: deletedCount > 0
                        ? "Сохранено: \(deletedCount) сообщ."
                        : "Сохранять контент до удаления",
                    iconColor: Color(hex: "#EF5350"), isOn: $deletedMessages
                )
                .onChange(of: deletedMessages) { v in
                    AorusGramConfig.setEnabled(.deletedMessages, v)
                }

                if deletedCount > 0 {
                    Button { showDeletedAll = true } label: {
                        HStack {
                            Spacer()
                            Text("Просмотреть удалённые (\(deletedCount)) →")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#EF5350"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }

            Divider().opacity(0.15)

            GlassToggleRow(
                icon: "camera.fill", title: "Защита от скриншотов",
                subtitle: "Блюр при скриншоте и записи экрана",
                iconColor: Color(hex: "#AB47BC"), isOn: $antiScreenshot
            )
            .onChange(of: antiScreenshot) { v in
                AorusGramConfig.setEnabled(.antiScreenshot, v)
                if v { AntiScreenshotManager.shared.enable() }
                else { AntiScreenshotManager.shared.disable() }
            }

            Divider().opacity(0.15)

            VStack(spacing: 0) {
                GlassToggleRow(
                    icon: "lock.rectangle.stack.fill", title: "Секретный пин",
                    subtitle: "Другой код — другой аккаунт",
                    iconColor: Color(hex: "#26A69A"), isOn: $secretPin
                )
                .onChange(of: secretPin) { v in
                    AorusGramConfig.setEnabled(.secretPin, v)
                    if v { showSecretPin = true }
                    else { SecretPinManager.shared.clearPins() }
                }

                if secretPin && SecretPinManager.shared.isConfigured {
                    Button { showSecretPin = true } label: {
                        HStack {
                            Spacer()
                            Text("Изменить пин-коды →")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#26A69A"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        settingsSection(title: "AI Функции", icon: "sparkles", color: Color(hex: "#FF6D00")) {
            GlassToggleRow(
                icon: "waveform", title: "Транскрипция войсов",
                subtitle: "Текст под голосовым — на устройстве",
                iconColor: Color(hex: "#FF6D00"), isOn: $voiceTranscript
            )
            .onChange(of: voiceTranscript) { v in
                AorusGramConfig.setEnabled(.voiceTranscription, v)
                if v {
                    VoiceTranscriptionManager.shared.requestPermission { _ in }
                }
            }

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
                subtitle: "Перевод в пузырьке (iOS 17.4+ или DeepL)",
                iconColor: Color(hex: "#42A5F5"), isOn: $translator
            )
            .onChange(of: translator) { v in AorusGramConfig.setEnabled(.translator, v) }

            Divider().opacity(0.15)

            VStack(spacing: 0) {
                GlassToggleRow(
                    icon: "arrow.uturn.left.circle.fill", title: "Авто-ответчик",
                    subtitle: AutoReplyManager.shared.isEnabled
                        ? "Активен · \"\(AutoReplyManager.shared.replyText.prefix(30))...\""
                        : "Отвечает пока ты занят",
                    iconColor: Color(hex: "#66BB6A"), isOn: $autoReply
                )
                .onChange(of: autoReply) { v in
                    AorusGramConfig.setEnabled(.autoReply, v)
                    AutoReplyManager.shared.isEnabled = v
                }

                if autoReply {
                    Button { showAutoReply = true } label: {
                        HStack {
                            Spacer()
                            Text("Настроить ответ →")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#66BB6A"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }
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
            .onChange(of: downloadAccel) { v in
                AorusGramConfig.setEnabled(.downloadAccel, v)
                if v { DownloadAccelerator.shared.updateConfig(DownloadAccelerator.shared.config) }
            }

            Divider().opacity(0.15)

            VStack(spacing: 0) {
                GlassToggleRow(
                    icon: "hand.raised.fill", title: "Анти-спам",
                    subtitle: "Автоблок по ключевым словам",
                    iconColor: Color(hex: "#EF5350"), isOn: $antiSpam
                )
                .onChange(of: antiSpam) { v in
                AorusGramConfig.setEnabled(.antiSpam, v)
                AntiSpamManager.shared.setEnabled(v)
            }

                if antiSpam {
                    Button { showSpamKeywords = true } label: {
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

            VStack(spacing: 0) {
                GlassToggleRow(
                    icon: "pin.fill", title: "Pinboard",
                    subtitle: "Доска важных сообщений из разных чатов",
                    iconColor: Color(hex: "#FFA726"), isOn: $pinboard
                )
                .onChange(of: pinboard) { v in AorusGramConfig.setEnabled(.pinboard, v) }

                if pinboard {
                    Button { showPinboard = true } label: {
                        HStack {
                            Spacer()
                            Text("Открыть Pinboard →")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#FFA726"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                }
            }
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

    // MARK: - AorusCode button

    private var aorusCodeButton: some View {
        Button { showAorusCode = true } label: {
            GlassCard {
                HStack(spacing: 14) {
                    ZStack {
                        LinearGradient(
                            colors: [Color(hex: "#FF6D00"), Color(hex: "#c62828")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(width: 44, height: 44)
                        Image(systemName: "key.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("AorusCode")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.primary)
                            if let tier = AorusCodeManager.shared.currentTier {
                                Text(tier.emoji + " " + tier.displayName)
                                    .font(.system(size: 11, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: "#FF6D00").opacity(0.15))
                                    .clipShape(Capsule())
                                    .foregroundColor(Color(hex: "#FF6D00"))
                            }
                        }
                        Text(AorusCodeManager.shared.isActivated
                             ? "Активирован · Управление"
                             : "Активировать код доступа")
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
        @ViewBuilder content: @escaping () -> Content
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
                        ForEach(keywords, id: \.self) { kw in Text(kw) }
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
    @State private var realPin  = ""
    @State private var decoyPin = ""
    @State private var errorMsg: String?
    @State private var saved = false

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                Form {
                    Section("Настройка двойного пин-кода") {
                        SecureField("Реальный пин (мин. 4 цифры)", text: $realPin)
                            .keyboardType(.numberPad)
                        SecureField("Пин-приманка (фейк, мин. 4 цифры)", text: $decoyPin)
                            .keyboardType(.numberPad)
                    }
                    Section {
                        Text("При вводе реального пина — открываются все чаты. При вводе пина-приманки — показывается пустой/другой аккаунт. Пины хранятся в защищённом Keychain.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    if let err = errorMsg {
                        Section {
                            Text(err).foregroundColor(.red).font(.footnote)
                        }
                    }
                    if saved {
                        Section {
                            Label("Сохранено в Keychain", systemImage: "checkmark.seal.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Секретный пин")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { savePins() }
                        .disabled(realPin.count < 4 || decoyPin.count < 4 || realPin == decoyPin)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func savePins() {
        guard realPin != decoyPin else {
            errorMsg = "Пины должны быть разными"
            return
        }
        do {
            try SecretPinManager.shared.setRealPin(realPin)
            try SecretPinManager.shared.setDecoyPin(decoyPin)
            errorMsg = nil
            saved = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

// MARK: - Auto-Reply Settings Sheet

struct AutoReplySettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var mgr = AutoReplyManager.shared

    var body: some View {
        NavigationView {
            ZStack {
                AorusAnimatedBackground()
                Form {
                    Section("Текст ответа") {
                        TextEditor(text: $mgr.replyText)
                            .frame(minHeight: 80)
                    }
                    Section("Кулдаун") {
                        Stepper("\(mgr.cooldownMinutes) минут между ответами",
                                value: $mgr.cooldownMinutes, in: 5...1440, step: 5)
                    }
                    Section("Исключения") {
                        Toggle("Не отвечать в группах", isOn: $mgr.skipGroups)
                        Toggle("Не отвечать в каналах", isOn: $mgr.skipChannels)
                    }
                    Section {
                        Text("Авто-ответчик отправляет одно сообщение на собеседника не чаще указанного интервала.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Авто-ответчик")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
