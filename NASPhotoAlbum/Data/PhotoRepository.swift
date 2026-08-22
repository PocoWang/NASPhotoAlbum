import Foundation

/**
 * 照片仓库：协调 NasRepository（扫描 NAS）与 Database（索引持久化）
 * （对应 Android 端 PhotoRepository，逻辑一比一移植）。
 *
 * 主要职责：
 * 1. 扫描用户已选目录，生成/更新照片索引。
 * 2. 提供索引查询接口（总数、已缓存、未缓存等）。
 * 3. 维护缓存状态标记。
 *
 * 所有方法为同步阻塞调用，须放后台队列执行。
 */
final class PhotoRepository {

    private let settings: SettingsStore
    private let database: Database
    private let nasRepository: NasRepository

    init(settings: SettingsStore, database: Database, nasRepository: NasRepository) {
        self.settings = settings
        self.database = database
        self.nasRepository = nasRepository
    }

    // MARK: - 查询接口

    func photoCount() -> Int { database.count() }

    func cachedPhotoCount() -> Int { database.cachedCount() }

    func getAllPhotos() -> [PhotoIndexEntity] { database.getAll() }

    func getCachedPhotos() -> [PhotoIndexEntity] { database.getCachedPhotos() }

    func getUncachedPhotos() -> [PhotoIndexEntity] { database.getUncachedPhotos() }

    func getTotalCachedSize() -> Int64 { database.getTotalCachedSize() }

    // MARK: - 缓存状态维护

    func markCached(fullPath: String, localPath: String) {
        database.markCached(fullPath: fullPath, localPath: localPath)
    }

    func markUncached(fullPath: String) {
        database.markUncached(fullPath: fullPath)
    }

    /// 标记实况视频已缓存（记录大小，计入配额）
    func markVideoCached(fullPath: String, videoBytes: Int64) {
        database.markVideoCached(fullPath: fullPath, videoBytes: videoBytes)
    }

    func updatePlayedTime(fullPath: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        database.updatePlayedTime(fullPath: fullPath, timestamp: timestamp)
    }

    func clearIndex() { database.clearAll() }

    /// 重置所有照片的播放时间戳（用于"重置播放位置"）
    func resetAllPlayedTime() { database.resetAllPlayedTime() }

    /// 批量重置所有缓存标记（用于"清空缓存"），返回重置条数
    @discardableResult
    func clearAllCacheMarks() -> Int { database.clearAllCacheMarks() }

    // MARK: - 扫描

    /**
     * 扫描已选目录，更新索引。
     *
     * 流程（与 Android 端一致）：
     * 1. 读取已选目录与 includeSubdir 开关。
     * 2. 对每个目录调用 NAS 列文件接口。
     * 3. 过滤图片文件，收集视频文件用于 iOS Live Photo 同名配对。
     * 4. 与现有索引比对，写入数据库；删除已不存在的记录。
     */
    func scanPhotos() -> Result<ScanResult, Error> {
        let selectedDirs = settings.getSelectedDirs()
        let includeSubdir = settings.includeSubdir
        let shareName = settings.getNasConfig()?.shareName ?? ""

        guard !selectedDirs.isEmpty else {
            return .failure(NSError(domain: "PhotoRepository", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "尚未选择照片目录"]))
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var scannedFiles: [NasDirNode] = []
        var videoFiles: [NasDirNode] = []
        // 未配置共享名时，从已选目录路径解析第一个段
        let effectiveShare: String
        if shareName.isEmpty {
            let first = selectedDirs.first ?? ""
            let trimmed = first.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let firstSegment = trimmed.split(separator: "/").first.map(String.init) ?? ""
            effectiveShare = firstSegment.isEmpty ? trimmed : firstSegment
        } else {
            effectiveShare = shareName
        }

        for dirPath in selectedDirs {
            let (_, innerPath) = parseSelectedDir(dirPath, fallbackShare: effectiveShare)
            let result = nasRepository.listFiles(shareName: effectiveShare, path: innerPath, recursive: includeSubdir)
            switch result {
            case .success(let files):
                // 仅保留图片文件
                scannedFiles.append(contentsOf: files.filter { isImageFile($0.name) })
                // 收集视频文件，用于 iOS Live Photo 同名配对（不作为独立照片入索引）
                videoFiles.append(contentsOf: files.filter { isLivePhotoVideoFile($0.name) })
            case .failure(let error):
                NSLog("扫描目录失败 %@: %@", dirPath, error.localizedDescription)
            }
            if scannedFiles.count >= AppConstants.scanMaxFiles { break }
        }

        // 视频配对索引：key = "父路径/文件名（去扩展名）"，同目录同名即视为 Live Photo 配对
        var videoMap: [String: NasDirNode] = [:]
        for video in videoFiles where videoMap[videoKeyOf(video.parentPath, video.name)] == nil {
            videoMap[videoKeyOf(video.parentPath, video.name)] = video
        }

        // 比对并写入数据库
        let existing = Dictionary(uniqueKeysWithValues: database.getAll().map { ($0.fullPath, $0) })
        var scannedPaths = Set<String>()
        var toUpsert: [PhotoIndexEntity] = []

        for file in scannedFiles {
            let fullPath = ("/\(effectiveShare)\(file.path)" as NSString)
                .replacingOccurrences(of: "//", with: "/")
            scannedPaths.insert(fullPath)
            let existingItem = existing[fullPath]
            // 查找同名配对视频（iOS：IMG_1234.HEIC + IMG_1234.MOV）
            let pairedVideo = videoMap[videoKeyOf(file.parentPath, file.name)]
            let entity = PhotoIndexEntity(
                fullPath: fullPath,
                shareName: effectiveShare,
                fileName: file.name,
                parentPath: file.parentPath,
                sizeBytes: file.size,
                lastModified: file.lastModified,
                fileExtension: file.extension,
                indexedAt: now,
                // 保留缓存状态
                isCached: existingItem?.isCached ?? false,
                localCachePath: existingItem?.localCachePath,
                lastPlayedAt: existingItem?.lastPlayedAt ?? 0,
                // 实况照片判定：iOS 同名配对视频存在；或安卓动态照片的内嵌视频
                // 当前确实已提取在本地（防"标记粘滞"：视频被清缓存/淘汰后标记必须回落，
                // 否则会永久误判为实况照片而播放时无视频）
                isLivePhoto: pairedVideo != nil || localVideoExists(fullPath),
                pairedVideoPath: pairedVideo.map { ("/\(effectiveShare)\($0.path)" as NSString)
                    .replacingOccurrences(of: "//", with: "/") },
                videoSizeBytes: existingItem?.videoSizeBytes ?? 0
            )
            toUpsert.append(entity)
        }

        // 写入新/更新的
        if !toUpsert.isEmpty { database.upsertAll(toUpsert) }
        // 删除已不存在的
        let removed = scannedPaths.isEmpty
            ? 0
            : database.deleteNotIn(keepPaths: Array(scannedPaths))

        let added = toUpsert.filter { existing[$0.fullPath] == nil }.count
        let unchanged = toUpsert.count - added

        // 记录扫描时间
        settings.setLastScanTime(now)

        return .success(ScanResult(added: added, removed: removed, unchanged: unchanged))
    }

    // MARK: - 内部工具

    /// 解析已选目录路径，返回 (shareName, innerPath)；dirPath 格式："/photo/2024" 或 "/photo"
    private func parseSelectedDir(_ dirPath: String, fallbackShare: String) -> (String, String) {
        let trimmed = dirPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return (fallbackShare, "/") }
        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let share = String(parts[0])
        let inner = parts.count > 1 ? "/\(parts[1])" : "/"
        return (share, inner)
    }

    /// 判断是否为图片文件
    private func isImageFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return AppConstants.imageExtensions.contains(ext)
    }

    /// 判断是否为实况照片配对视频文件
    private func isLivePhotoVideoFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return AppConstants.livePhotoVideoExtensions.contains(ext)
    }

    /// 配对键：父路径 + 去扩展名的文件名（iOS Live Photo 的 IMG_1234.HEIC / IMG_1234.MOV 同名配对）
    private func videoKeyOf(_ parentPath: String, _ name: String) -> String {
        let base = (name as NSString).deletingPathExtension.lowercased()
        let trimmedParent = parentPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmedParent.isEmpty ? base : "\(trimmedParent)/\(base)"
    }

    /// 安卓动态照片的内嵌视频是否已提取在本地（original_cache 中的 *_live.mp4）
    private func localVideoExists(_ fullPath: String) -> Bool {
        return CacheManager.fileSize(at: CacheManager.liveVideoURL(forFullPath: fullPath)) > 0
    }
}
