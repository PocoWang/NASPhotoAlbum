import Foundation

/**
 * 缓存统计（对应 Android 端 CacheStats）。
 */
struct CacheStats {
    var totalPhotos: Int = 0
    var cachedPhotos: Int = 0
    var usedBytes: Int64 = 0
    var limitBytes: Int64 = 0

    /// 已用比例 0~1
    var usedRatio: Double {
        guard limitBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(limitBytes)
    }
}

/**
 * 缓存总管：管理原图本地缓存目录，负责 LRU 淘汰与容量评估
 * （对应 Android 端 CacheManager，逻辑一比一移植）。
 *
 * - 原图缓存目录：Caches/original_cache
 * - 文件名使用 fullPath 的 SHA-256 哈希前 32 个十六进制字符，避免路径非法字符。
 *
 * 与 PhotoRepository 协作维护 isCached 标记，避免越层操作数据库。
 */
final class CacheManager {

    private let settings: SettingsStore
    private let photoRepository: PhotoRepository

    // MARK: - 静态路径工具（PhotoRepository 扫描时也需判定实况视频是否已在本地）

    /** 原图缓存目录（懒创建） */
    static let originalCacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent(AppConstants.cacheDirName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// fullPath → 稳定哈希文件名（保留原扩展名便于播放器/解码器推断格式）
    static func hashName(_ fullPath: String) -> String {
        let hex = String(SHA256.hexString(of: fullPath).prefix(32))
        let ext = (fullPath as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hex : "\(hex).\(ext)"
    }

    /// 根据 fullPath 取实况视频本地文件（可能不存在），统一 .mp4 后缀便于播放器识别
    static func liveVideoURL(forFullPath fullPath: String) -> URL {
        let base = (hashName(fullPath) as NSString).deletingPathExtension
        return originalCacheDir.appendingPathComponent("\(base)_live.mp4")
    }

    /// 文件大小（字节，不存在返回 0）
    static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    init(settings: SettingsStore, photoRepository: PhotoRepository) {
        self.settings = settings
        self.photoRepository = photoRepository
    }

    // MARK: - 路径解析

    /// 根据 fullPath 取本地原图文件（可能不存在）
    func localFileFor(fullPath: String) -> URL {
        return CacheManager.originalCacheDir.appendingPathComponent(CacheManager.hashName(fullPath))
    }

    /// 根据 fullPath 取实况视频本地文件（可能不存在）
    func localVideoFileFor(fullPath: String) -> URL {
        return CacheManager.liveVideoURL(forFullPath: fullPath)
    }

    // MARK: - 容量评估

    /// 当前已缓存原图占用空间（字节，含实况视频）
    func usedSize() -> Int64 {
        return photoRepository.getTotalCachedSize()
    }

    /// 用户设定的缓存上限（字节）
    func cacheLimit() -> Int64 {
        return settings.getCacheSizeBytes()
    }

    /// 缓存安全阈值（达到此值后停止下载）
    func safeLimit() -> Int64 {
        return Int64(Double(cacheLimit()) * AppConstants.cacheSafeRatio)
    }

    /// 是否还能继续下载（至少留 1MB 给下一张）
    func canDownloadMore() -> Bool {
        let limit = cacheLimit()
        if limit <= 0 { return false }
        let used = usedSize()
        if used >= safeLimit() { return false }
        return (safeLimit() - used) > 1 * 1024 * 1024
    }

    // MARK: - 缓存事件

    /**
     * 标记某照片已下载完成。
     * - 写入数据库的 isCached/localCachePath
     * - 不立即触发淘汰（由调用方按需调用 evictIfNeeded）
     */
    func onOriginalDownloaded(fullPath: String, localFile: URL) {
        photoRepository.markCached(fullPath: fullPath, localPath: localFile.path)
    }

    /// 标记某照片的实况视频已缓存（大小计入缓存配额）
    func onVideoCached(fullPath: String, videoFile: URL) {
        photoRepository.markVideoCached(fullPath: fullPath, videoBytes: CacheManager.fileSize(at: videoFile))
    }

    /// 取可用于播放的实况视频文件（本地文件存在才返回）
    func findLiveVideo(photo: PhotoIndexEntity) -> URL? {
        guard photo.isLivePhoto else { return nil }
        let file = localVideoFileFor(fullPath: photo.fullPath)
        return CacheManager.fileSize(at: file) > 0 ? file : nil
    }

    // MARK: - LRU 淘汰

    /**
     * 执行一次 LRU 淘汰，直至 usedSize <= safeLimit。
     *
     * 策略（与 Android 端一致）：
     * 1. 取所有已缓存照片，按 lastPlayedAt 升序（最久未播在前面，0 表示从未播放）。
     * 2. 依次删除文件并标记 isCached = 0，直至 usedSize 降至 safeLimit 以下。
     * 3. 不淘汰 excludePaths 中的照片（如正在播放的照片）。
     */
    func evictIfNeeded(excludePaths: [String] = []) {
        let limit = safeLimit()
        var used = usedSize()
        if used <= limit { return }

        let fm = FileManager.default
        let excludeSet = Set(excludePaths)
        let cached = photoRepository.getCachedPhotos()
            .filter { !excludeSet.contains($0.fullPath) }
            .sorted { $0.lastPlayedAt < $1.lastPlayedAt }

        for item in cached {
            if used <= limit { break }
            let file = localFileFor(fullPath: item.fullPath)
            let size = CacheManager.fileSize(at: file)
            guard size > 0 else {
                // 文件已不存在但数据库仍标记为 cached：修正状态
                photoRepository.markUncached(fullPath: item.fullPath)
                continue
            }
            // 实况视频随原图一同删除，体积一并释放
            let videoFile = localVideoFileFor(fullPath: item.fullPath)
            let videoSize = CacheManager.fileSize(at: videoFile)
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: videoFile)
            photoRepository.markUncached(fullPath: item.fullPath)
            used -= (size + videoSize)
        }
    }

    // MARK: - 维护操作

    /**
     * 仅清空缓存文件（保留索引）。
     * - 删除 original_cache 下所有文件
     * - 将数据库中所有 isCached 置为 false、清空 localCachePath（单次 SQL 批量重置）
     *
     * 用于扫描前强制重新随机下载，以及设置页"清空缓存"按钮：
     * 索引保留，用户无需重新扫描，后台会重新下载未缓存的原图。
     */
    func clearOriginalCacheOnly() {
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(
            at: CacheManager.originalCacheDir,
            includingPropertiesForKeys: nil
        ) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        let resetCount = photoRepository.clearAllCacheMarks()
        NSLog("原图缓存已清空（保留索引），重置 %d 条缓存标记", resetCount)
    }

    /// 完全清空：缓存文件 + 索引（用于彻底重置）
    func clearAll() {
        let fm = FileManager.default
        try? fm.removeItem(at: CacheManager.originalCacheDir)
        try? fm.createDirectory(
            at: CacheManager.originalCacheDir,
            withIntermediateDirectories: true
        )
        photoRepository.clearIndex()
    }

    /**
     * 自检：扫描数据库中标记为 cached 但文件不存在的项，修正其状态。
     * 适用于系统清理缓存后恢复。
     */
    func verifyIntegrity() {
        let fm = FileManager.default
        let cached = photoRepository.getCachedPhotos()
        for item in cached {
            let file = localFileFor(fullPath: item.fullPath)
            if !fm.fileExists(atPath: file.path) {
                try? fm.removeItem(at: localVideoFileFor(fullPath: item.fullPath)) // 清理可能残留的实况视频
                photoRepository.markUncached(fullPath: item.fullPath)
            }
        }
    }

    // MARK: - 状态查询（UI 轮询 / photoIndexDidChange 通知后重查）

    /// 当前缓存统计（等价于 Android 端 observeStats 的即时值）
    func currentStats() -> CacheStats {
        return CacheStats(
            totalPhotos: photoRepository.photoCount(),
            cachedPhotos: photoRepository.cachedPhotoCount(),
            usedBytes: photoRepository.getTotalCachedSize(),
            limitBytes: cacheLimit()
        )
    }
}
