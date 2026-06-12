import UIKit
import Foundation
import TelegramCore
import AccountContext

// MARK: - AorusCode Compose Sheet
//
// Bottom sheet presented via long-press on the chat attachment button when
// AorusCode is enabled in AorusGram settings.
// The user writes a visible cover text and a secret message; on send, the
// pair is encoded into a zero-width steganographic payload by AorusStealthCodec
// and enqueued as a regular Telegram message. Non-AorusGram clients see only
// the cover text; AorusGram recipients reveal the secret under a spoiler.

public final class AorusCodeComposeViewController: UIViewController {

    // MARK: - State

    private let context: AccountContext
    private let peerId: PeerId
    private let isRu: Bool

    // MARK: - Views

    private let handleBar = UIView()
    private let titleLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let coverCard = UIView()
    private let coverHeaderLabel = UILabel()
    private let coverTextView = UITextView()
    private let secretCard = UIView()
    private let secretHeaderLabel = UILabel()
    private let secretTextView = UITextView()
    private let hintLabel = UILabel()
    private let sendButton = UIButton(type: .system)

    private var scrollViewBottomConstraint: NSLayoutConstraint!
    private var coverIsEmpty = true
    private var secretIsEmpty = true

    // MARK: - Init

    public init(context: AccountContext, peerId: PeerId) {
        self.context = context
        self.peerId = peerId
        self.isRu = AorusLang.current == .ru
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        registerKeyboardNotifications()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateSendEnabled()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Construction

    private func buildUI() {
        view.backgroundColor = .systemBackground

        // Grab handle
        handleBar.backgroundColor = UIColor.separator
        handleBar.layer.cornerRadius = 2.5
        view.addSubview(handleBar)

        // Title
        titleLabel.text = "AorusCode"
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        // Cancel
        cancelButton.setTitle(isRu ? "Отмена" : "Cancel", for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 17)
        cancelButton.addTarget(self, action: #selector(onCancel), for: .touchUpInside)
        view.addSubview(cancelButton)

        // Separator
        let sep = UIView()
        sep.backgroundColor = .separator
        view.addSubview(sep)

        // Scroll + content
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        // Cover card
        coverCard.backgroundColor = .secondarySystemBackground
        coverCard.layer.cornerRadius = 14
        coverCard.layer.cornerCurve = .continuous
        contentView.addSubview(coverCard)

        coverHeaderLabel.text = isRu ? "Видимый текст" : "Visible Text"
        coverHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        coverHeaderLabel.textColor = .secondaryLabel
        coverHeaderLabel.textAlignment = .left
        contentView.addSubview(coverHeaderLabel)

        configureTextView(coverTextView,
                          placeholder: isRu ? "Что увидят все..." : "What everyone sees...")
        coverTextView.delegate = self
        contentView.addSubview(coverTextView)

        // Secret card
        secretCard.backgroundColor = .secondarySystemBackground
        secretCard.layer.cornerRadius = 14
        secretCard.layer.cornerCurve = .continuous
        contentView.addSubview(secretCard)

        secretHeaderLabel.text = isRu ? "Скрытое сообщение" : "Hidden Message"
        secretHeaderLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        secretHeaderLabel.textColor = UIColor(red: 1.0, green: 0.43, blue: 0.0, alpha: 1.0)
        contentView.addSubview(secretHeaderLabel)

        configureTextView(secretTextView,
                          placeholder: isRu ? "Только для AorusGram..." : "AorusGram users only...")
        secretTextView.delegate = self
        contentView.addSubview(secretTextView)

        // Hint
        hintLabel.text = isRu
            ? "Скрытое сообщение видят только пользователи AorusGram — под спойлером."
            : "Hidden message is only visible to AorusGram users — under a spoiler."
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabel
        hintLabel.numberOfLines = 0
        contentView.addSubview(hintLabel)

        // Send button
        sendButton.setTitle(isRu ? "Отправить" : "Send", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.setTitleColor(UIColor.white.withAlphaComponent(0.5), for: .disabled)
        sendButton.backgroundColor = UIColor(red: 1.0, green: 0.43, blue: 0.0, alpha: 1.0)
        sendButton.layer.cornerRadius = 14
        sendButton.layer.cornerCurve = .continuous
        sendButton.addTarget(self, action: #selector(onSend), for: .touchUpInside)
        contentView.addSubview(sendButton)

        installConstraints(separator: sep)
    }

    private func configureTextView(_ tv: UITextView, placeholder: String) {
        tv.font = .systemFont(ofSize: 16)
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.isScrollEnabled = false
        tv.textColor = .placeholderText
        tv.text = placeholder
        tv.layer.cornerRadius = 14
        tv.layer.cornerCurve = .continuous
    }

    private func installConstraints(separator: UIView) {
        let m: CGFloat = 16
        let subviews: [UIView] = [handleBar, titleLabel, cancelButton, separator,
                                   scrollView, contentView, coverHeaderLabel, coverCard,
                                   coverTextView, secretHeaderLabel, secretCard,
                                   secretTextView, hintLabel, sendButton]
        subviews.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        scrollViewBottomConstraint = scrollView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor)

        NSLayoutConstraint.activate([
            handleBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            handleBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            handleBar.widthAnchor.constraint(equalToConstant: 36),
            handleBar.heightAnchor.constraint(equalToConstant: 5),

            titleLabel.topAnchor.constraint(equalTo: handleBar.bottomAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            cancelButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),

            separator.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollViewBottomConstraint,

            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // Cover
            coverHeaderLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: m),
            coverHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            coverCard.topAnchor.constraint(equalTo: coverHeaderLabel.bottomAnchor, constant: 6),
            coverCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            coverCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            coverTextView.topAnchor.constraint(equalTo: coverCard.topAnchor),
            coverTextView.leadingAnchor.constraint(equalTo: coverCard.leadingAnchor),
            coverTextView.trailingAnchor.constraint(equalTo: coverCard.trailingAnchor),
            coverTextView.bottomAnchor.constraint(equalTo: coverCard.bottomAnchor),
            coverTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),

            // Secret
            secretHeaderLabel.topAnchor.constraint(equalTo: coverCard.bottomAnchor, constant: m),
            secretHeaderLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            secretCard.topAnchor.constraint(equalTo: secretHeaderLabel.bottomAnchor, constant: 6),
            secretCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            secretCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            secretTextView.topAnchor.constraint(equalTo: secretCard.topAnchor),
            secretTextView.leadingAnchor.constraint(equalTo: secretCard.leadingAnchor),
            secretTextView.trailingAnchor.constraint(equalTo: secretCard.trailingAnchor),
            secretTextView.bottomAnchor.constraint(equalTo: secretCard.bottomAnchor),
            secretTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 70),

            hintLabel.topAnchor.constraint(equalTo: secretCard.bottomAnchor, constant: 10),
            hintLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            sendButton.topAnchor.constraint(equalTo: hintLabel.bottomAnchor, constant: 20),
            sendButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            sendButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            sendButton.heightAnchor.constraint(equalToConstant: 52),
            sendButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - Keyboard

    private func registerKeyboardNotifications() {
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval,
              let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return }

        let keyboardHeight = max(0, UIScreen.main.bounds.height - frame.minY)
        let safeBottom = view.safeAreaInsets.bottom
        scrollViewBottomConstraint.constant = -(max(0, keyboardHeight - safeBottom))

        UIView.animate(withDuration: duration,
                       delay: 0,
                       options: UIView.AnimationOptions(rawValue: curve << 16)) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: - Send state

    private func updateSendEnabled() {
        sendButton.isEnabled = !secretIsEmpty
        sendButton.alpha = secretIsEmpty ? 0.5 : 1.0
    }

    // MARK: - Actions

    @objc private func onCancel() {
        dismiss(animated: true)
    }

    @objc private func onSend() {
        let cover = coverIsEmpty ? "" : (coverTextView.text ?? "")
        let secret = secretIsEmpty ? "" : (secretTextView.text ?? "")
        guard !secret.isEmpty else { return }

        let encoded = AorusStealthCodec.shared.encode(cover: cover, secret: secret)
        let _ = enqueueMessages(account: context.account, peerId: peerId, messages: [
            .message(
                text: encoded,
                attributes: [],
                inlineStickers: [:],
                mediaReference: nil,
                threadId: nil,
                replyToMessageId: nil,
                replyToStoryId: nil,
                localGroupingKey: nil,
                correlationId: nil,
                bubbleUpEmojiOrStickersets: []
            )
        ]).startStandalone()
        dismiss(animated: true)
    }
}

// MARK: - UITextViewDelegate

extension AorusCodeComposeViewController: UITextViewDelegate {

    public func textViewDidBeginEditing(_ textView: UITextView) {
        let isCover = textView === coverTextView
        let isEmpty = isCover ? coverIsEmpty : secretIsEmpty
        if isEmpty {
            textView.text = nil
            textView.textColor = .label
        }
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        let isCover = textView === coverTextView
        if (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let placeholder: String
            if isCover {
                placeholder = isRu ? "Что увидят все..." : "What everyone sees..."
                coverIsEmpty = true
            } else {
                placeholder = isRu ? "Только для AorusGram..." : "AorusGram users only..."
                secretIsEmpty = true
            }
            textView.text = placeholder
            textView.textColor = .placeholderText
        }
        updateSendEnabled()
    }

    public func textViewDidChange(_ textView: UITextView) {
        let isCover = textView === coverTextView
        let nowEmpty = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isCover {
            coverIsEmpty = nowEmpty
        } else {
            secretIsEmpty = nowEmpty
        }
        updateSendEnabled()
    }
}
