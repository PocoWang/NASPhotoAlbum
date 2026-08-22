import Foundation

/**
 * 扫描/下载协调器（替代 Android 端 WorkManager + ScanPhotosWorker + DownloadOriginalWorker + WorkScheduler）。
 *
 * iOS 12 没有 WorkManager/BGTaskScheduler（后者需 iOS 13+），而本应用是相框类应用、
 * 绝大多数时间在前台播放，因此以前台定时循环 + 后台串行队列实现同等调度：
 *
 * - scanNow(clearCache:)：REPLACE 语义 —— 重复触发时旧任务尽快让位（generation 自增）
 *   1.（可选）清空原图缓存文件（保留文件名索引）
 *   2. 扫描 NAS 指定目录，保存文件名并与现有索引对比更新（首页照片数量自动刷新）
 *   3. 随机下载原图，缓存达到设定上限后自动停止（缓存数量实时刷新）
 * - downloadNow()：KEEP 语义 —— 已有下载在执行则跳过
 * - startAutoScanLoop()：每 30 分钟检查一次「距上次扫描是否超过设定周期」，
 *   到期自动执行 scanNow(clearCache: true)（与 Android 每日周期自动扫描一致）
 */
final class ScanCoordinator {

    private let settings: SettingsStore
    private let photoRepository: PhotoRepository
    private let nasRepository: NasRepository
    private let cacheManager: CacheManager

    /// 串行工作队列：扫描与下载都在此队列执行，天然互斥
    private let workQueue = DispatchQueue(label: "nasphotoalbum.scan", qos: .utility)

    /// 任务代数：scanNow 触发时自增，旧任务发现代数变化即放弃（REPLACE 语义）
    private var generation = 0
    private let generationLock = NSLock()

    /// 下载取消标记
    private var downloadCancelled = false
    private let stateLock = NSLock()

    /// 自动扫描检查定时器
    private var autoCheckTimer: Timer?

    /// 下载/扫描状态变化通知（主线程），UI 据此刷新"正在扫描/下载"提示
    static let workStateDidChange = Notification.Name("scanWorkStateDidChange")

    /// 供 UI 显示的执行状态（状态在 workQueue 上变更，UI 仅在主线程读取）
    private(set) var isScanning = false {
        didSet { postStateChange() }
    }
    private(set) var isDownloading = false {
        didSet { postStateChange() }
    }

    init(
        settings: SettingsStore,
        photoRepository: PhotoRepository,
        nasRepository: NasRepository,
        cacheManager: CacheManager
    ) {
        self.settings = settings
        self.photoRepository = photoRepository
        self.nasRepository = nasRepository
        self.cacheManager = cacheManager
    }

    // MARK: - 立即扫描（首页/设置页按钮 → 清缓存；启动同步 → 增量）

    /**
     * 立即触发一次扫描。
     * @param clearCache true 时扫描前清空原图缓存（保留文件名索引），完成后重新随机下载至设定上限
     */
    func scanNow(clearCache: Bool, completion: ((Result<ScanResult, Error>) -> Void)? = nil) {
        generationLock.lock()
        generation += 1
        let myGeneration = generation
        generationLock.unlock()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.isScanning = true
            defer { self.isScanning = false }

            // 1. 扫描前清空原图缓存（保留文件名索引），强制按最新索引重新随机下载
            if clearCache {
                self.cacheManager.clearOriginalCacheOnly()
            }

            // 2. 扫描 NAS 指定目录，保存文件名并与现有索引对比更新
            let result = self.photoRepository.scanPhotos()
            switch result {
            case .success(let scanResult):
                NSLog("扫描完成：新增 %d，删除 %d，不变 %d", scanResult.added, scanResult.removed, scanResult.unchanged)
            case .failure(let error):
                NSLog("扫描失败：%@", error.localizedDescription)
            }

            // 3. 触发原图下载（随机排序，缓存达到设定上限后自动停止）
            //    代数已变化说明有更新的扫描请求，本代任务让位
            if self.currentGeneration() == myGeneration {
                self.runDownloadLoop()
            }

            DispatchQueue.main.async { completion?(result) }
        }
    }

    /// 立即触发一次原图下载（KEEP 语义：已在下载则跳过）
    func downloadNow() {
        workQueue.async { [weak self] in
            self?.runDownloadLoop()
        }
    }

    /// 取消正在执行的下载任务（缓存上限变更时用）
    func cancelDownload() {
        stateLock.lock()
        downloadCancelled = true
        stateLock.unlock()
    }

    // MARK: - 自动扫描循环

    /// App 启动/回前台时调用：先做一次到期检查，然后每 30 分钟复查
    func maybeAutoScan() {
        checkScanDue()
        startAutoScanLoop()
    }

    func startAutoScanLoop() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.autoCheckTimer != nil { return }
            self.autoCheckTimer = Timer.scheduledTimer(
                withTimeInterval: 30 * 60,
                repeats: true
            ) { [weak self] _ in
                self?.checkScanDue()
            }
        }
    }

    func stopAutoScanLoop() {
        DispatchQueue.main.async { [weak self] in
            self?.autoCheckTimer?.invalidate()
            self?.autoCheckTimer = nil
        }
    }

    /// 距上次扫描是否已超过设定周期，超过则自动扫描（每日自动扫描同样清缓存后随机下载）
    private func checkScanDue() {
        let period = settings.getScanPeriod()
        guard period != .manualOnly else { return }
        let intervalMs = period.intervalDays * 24 * 3600 * 1000
        let last = settings.getLastScanTime()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        if last == 0 || now - last >= intervalMs {
            scanNow(clearCache: true)
        }
    }

    // MARK: - 下载循环（对应 Android DownloadOriginalWorker）

    /// 下载循环（workQueue 为串行队列，天然满足 KEEP 语义：同一时间只有一轮下载）
    private func runDownloadLoop() {
        isDownloading = true
        stateLock.lock()
        downloadCancelled = false
        stateLock.unlock()

        defer { isDownloading = false }

        // 前置校验：未配置 NAS
        guard nasRepository.isConfigured else {
            NSLog("未配置 NAS，跳过下载")
            return
        }

        // 缓存完整性自检（修正系统清理缓存后的状态）
        cacheManager.verifyIntegrity()

        // 缓存已满
        guard cacheManager.canDownloadMore() else {
            NSLog("缓存已满，跳过本次下载")
            return
        }

        let uncached = photoRepository.getUncachedPhotos()
        guard !uncached.isEmpty else {
            NSLog("没有待下载的照片")
            return
        }

        // 随机排序，保证幻灯片多样化
        let queue = uncached.shuffled()
        var failStreak = 0
        let maxFailStreak = 3

        for photo in queue {
            if isCancelled() { break }
            guard cacheManager.canDownloadMore() else {
                NSLog("下载途中缓存已满，停止后续下载")
                break
            }

            let dest = cacheManager.localFileFor(fullPath: photo.fullPath)
            // 拼接远程路径（parentPath 形如 "/2024/06"，fileName 形如 "IMG_001.jpg"）
            let remotePath = buildRemotePath(photo.parentPath, photo.fileName)

            let result = nasRepository.downloadFile(shareName: photo.shareName, remotePath: remotePath, to: dest)
            switch result {
            case .success:
                cacheManager.onOriginalDownloaded(fullPath: photo.fullPath, localFile: dest)
                fetchLiveVideo(photo: photo, originalFile: dest)
                cacheManager.evictIfNeeded(excludePaths: [photo.fullPath])
                failStreak = 0
            case .failure(let error):
                failStreak += 1
                NSLog("下载失败 %@：%@", photo.fileName, error.localizedDescription)
                if failStreak >= maxFailStreak {
                    NSLog("连续 %d 次失败，停止本轮下载", maxFailStreak)
                    return
                }
            }
        }
    }

    private func isCancelled() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return downloadCancelled
    }

    private func currentGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    /** 拼接远程路径，处理首尾斜杠 */
    private func buildRemotePath(_ parentPath: String, _ fileName: String) -> String {
        let parent = parentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return parent.isEmpty ? "/\(fileName)" : "/\(parent)/\(fileName)"
    }

    /**
     * 原图下载成功后获取实况视频：
     * - iOS Live Photo（pairedVideoPath 非空）：从 NAS 下载同名 .mov
     * - 安卓动态照片（jpg/jpeg）：从文件末尾提取内嵌 MP4 片段
     * 失败不影响原图缓存（播放时自动回退静态图）。
     */
    private func fetchLiveVideo(photo: PhotoIndexEntity, originalFile: URL) {
        let videoDest = cacheManager.localVideoFileFor(fullPath: photo.fullPath)
        do {
            if let pairedPath = photo.pairedVideoPath {
                // pairedVideoPath 形如 "/share/dir/IMG_1234.mov"，转为共享内路径
                let prefix = "/\(photo.shareName)"
                var innerPath = pairedPath
                if innerPath.hasPrefix(prefix) {
                    innerPath = String(innerPath.dropFirst(prefix.count))
                    if innerPath.isEmpty { innerPath = "/" }
                }
                let result = nasRepository.downloadFile(
                    shareName: photo.shareName,
                    remotePath: innerPath,
                    to: videoDest
                )
                if case .success = result, CacheManager.fileSize(at: videoDest) > 0 {
                    cacheManager.onVideoCached(fullPath: photo.fullPath, videoFile: videoDest)
                } else {
                    try? FileManager.default.removeItem(at: videoDest)
                }
            } else if AppConstants.motionPhotoExtensions.contains(photo.fileExtension) {
                if MotionPhotoExtractor.extractVideo(from: originalFile, to: videoDest) {
                    cacheManager.onVideoCached(fullPath: photo.fullPath, videoFile: videoDest)
                } else {
                    try? FileManager.default.removeItem(at: videoDest)
                }
            }
        }
    }

    private func postStateChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: ScanCoordinator.workStateDidChange, object: nil)
        }
    }
}
