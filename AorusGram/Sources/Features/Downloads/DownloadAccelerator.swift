import Foundation

// Ускоритель загрузок/отгрузок файлов через Telegram MTProto.
// Стратегия: параллельная загрузка частей через несколько DC-соединений,
// увеличенный размер чанка, приоритизация активного чата.
final class DownloadAccelerator {
    static let shared = DownloadAccelerator()
    private init() { load() }

    // MARK: - Config

    struct Config: Codable {
        var parallelConnections: Int  = 8    // до 8 соединений на файл (TG default: 4)
        var chunkSizeMB: Double       = 2.0  // размер чанка (TG default: 0.5 MB)
        var prefetchNextMedia: Bool   = true // загружать следующие медиа заранее
        var maxConcurrentFiles: Int   = 5    // одновременных загрузок
        var uploadParallelParts: Int  = 8    // параллельных частей при отправке
        var prioritizeActiveChat: Bool = true
    }

    private(set) var config = Config()
    private let defaultsKey = "aorusgram_download_accel"

    func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Config.self, from: data) else { return }
        config = saved
    }

    func updateConfig(_ new: Config) {
        config = new
        UserDefaults.standard.set(try? JSONEncoder().encode(new), forKey: defaultsKey)
        applyToEngine()
    }

    // MARK: - Apply to Telegram MTProto network layer

    private func applyToEngine() {
        // Патч network.maxConnectionsPerContext в TelegramCore
        setMTProtoSetting("maxDownloadConnections", value: config.parallelConnections)
        setMTProtoSetting("downloadChunkSize",      value: Int(config.chunkSizeMB * 1024 * 1024))
        setMTProtoSetting("maxUploadParts",         value: config.uploadParallelParts)
        setMTProtoSetting("maxConcurrentDownloads", value: config.maxConcurrentFiles)
    }

    private func setMTProtoSetting(_ key: String, value: Int) {
        UserDefaults.standard.set(value, forKey: "aorusgram_mtproto_\(key)")
        NotificationCenter.default.post(
            name: .aorusMTProtoSettingChanged,
            object: nil,
            userInfo: ["key": key, "value": value]
        )
    }

    // MARK: - Download Task Manager

    private var activeTasks: [String: DownloadTask] = [:]
    private let taskQueue = DispatchQueue(label: "aorusgram.download_tasks", attributes: .concurrent)

    func scheduleDownload(fileId: String, dcId: Int, size: Int64, priority: DownloadPriority) -> DownloadTask {
        let task = DownloadTask(
            fileId:              fileId,
            dcId:                dcId,
            totalSize:           size,
            parallelConnections: config.parallelConnections,
            chunkSize:           Int64(config.chunkSizeMB * 1024 * 1024),
            priority:            priority
        )
        taskQueue.async(flags: .barrier) { self.activeTasks[fileId] = task }
        task.start()
        return task
    }

    func cancelDownload(fileId: String) {
        taskQueue.async(flags: .barrier) {
            self.activeTasks[fileId]?.cancel()
            self.activeTasks.removeValue(forKey: fileId)
        }
    }
}

enum DownloadPriority: Int, Comparable {
    case low = 0, normal = 1, high = 2, urgent = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

final class DownloadTask {
    let fileId: String
    let dcId: Int
    let totalSize: Int64
    let parallelConnections: Int
    let chunkSize: Int64
    let priority: DownloadPriority

    private(set) var downloadedBytes: Int64 = 0
    private(set) var isCancelled = false
    private(set) var isCompleted = false

    private var operationQueue: OperationQueue

    var progress: Double { totalSize > 0 ? Double(downloadedBytes) / Double(totalSize) : 0 }

    init(fileId: String, dcId: Int, totalSize: Int64,
         parallelConnections: Int, chunkSize: Int64, priority: DownloadPriority) {
        self.fileId             = fileId
        self.dcId               = dcId
        self.totalSize          = totalSize
        self.parallelConnections = parallelConnections
        self.chunkSize          = chunkSize
        self.priority           = priority

        operationQueue = OperationQueue()
        operationQueue.maxConcurrentOperationCount = parallelConnections
        operationQueue.qualityOfService = priority == .urgent ? .userInitiated : .utility
    }

    func start() {
        let chunks = stride(from: Int64(0), to: totalSize, by: chunkSize).map { offset in
            min(chunkSize, totalSize - offset)
        }
        for (index, chunkLen) in chunks.enumerated() {
            let offset = Int64(index) * chunkSize
            operationQueue.addOperation { [weak self] in
                self?.downloadChunk(offset: offset, length: chunkLen)
            }
        }
    }

    private func downloadChunk(offset: Int64, length: Int64) {
        guard !isCancelled else { return }
        // Реальный вызов MTProto upload.getFile / upload.getWebFile
        // интегрируется через TelegramCore FetchedMediaResource
        NotificationCenter.default.post(
            name: .aorusDownloadChunkRequested,
            object: nil,
            userInfo: ["fileId": fileId, "dcId": dcId, "offset": offset, "length": length]
        )
        downloadedBytes += length
        if downloadedBytes >= totalSize { isCompleted = true }
    }

    func cancel() {
        isCancelled = true
        operationQueue.cancelAllOperations()
    }
}

extension Notification.Name {
    static let aorusMTProtoSettingChanged    = Notification.Name("aorusgram_mtproto_setting")
    static let aorusDownloadChunkRequested   = Notification.Name("aorusgram_download_chunk")
}
