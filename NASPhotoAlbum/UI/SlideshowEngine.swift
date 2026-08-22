import Foundation

/**
 * 后续照片（本地缓存文件 + NAS 原始拍摄时间）。
 * 拍摄时间用于 DV 日期戳等叠加效果（缓存文件的修改时间是下载时间，不可用）。
 */
struct UpcomingPhoto {
    var file: URL
    var timeMs: Int64
}

/**
 * 幻灯片播放状态机（对应 Android 端 SlideshowViewModel / PlaybackState）。
 */
enum PlaybackState {
    /// 加载中（首次进入或缓存为空，等待下载）
    case loading
    /// 无照片可播（已扫描但缓存仍为空，或未配置 NAS）
    case empty(reason: String)
    /// 正在播放
    case playing(current: PhotoIndexEntity, localFile: URL, index: Int, total: Int,
                 upcoming: [UpcomingPhoto], videoFile: URL?)
    /// 已暂停
    case paused(current: PhotoIndexEntity, localFile: URL, index: Int, total: Int,
                upcoming: [UpcomingPhoto], videoFile: URL?)

    var photoPath: String? {
        switch self {
        case .playing(let cur, _, _, _, _, _): return cur.fullPath
        case .paused(let cur, _, _, _, _, _): return cur.fullPath
        default: return nil
        }
    }
}

/**
 * 幻灯片引擎。
 *
 * 职责（与 Android 端一致）：
 * 1. 订阅已缓存照片列表（Database 变更通知），按 PlayOrder 排序生成播放列表
 * 2. 维护当前播放索引，提供 next/prev/play/pause 接口
 * 3. 定时器按 intervalMs 自动推进；步长 = 上页实际展示的不重复照片数
 * 4. 播放中的照片更新 lastPlayedAt（驱动 LRU）
 * 5. 缓存为空时自动触发后台下载
 */
final class SlideshowEngine {

    private let settings: SettingsStore
    private let photoRepository: PhotoRepository
    private let cacheManager: CacheManager
    private let scanCoordinator: ScanCoordinator

    /// 状态回调（主线程）
    var onStateChange: ((PlaybackState) -> Void)?

    private(set) var state: PlaybackState = .loading {
        didSet { onStateChange?(state) }
    }

    private var playlist: [PhotoIndexEntity] = []
    private var currentIndex = 0
    private var playing = false
    private var ticker: Timer?
    private var currentPath: String?

    /// 上一页实际展示的照片数（渲染器回报），作为下一次推进的步长
    private var lastPageConsumed = 1

    init(
        settings: SettingsStore,
        photoRepository: PhotoRepository,
        cacheManager: CacheManager,
        scanCoordinator: ScanCoordinator
    ) {
        self.settings = settings
        self.photoRepository = photoRepository
        self.cacheManager = cacheManager
        self.scanCoordinator = scanCoordinator

        rebuildPlaylist()
        NotificationCenter.default.addObserver(
            forName: Database.photoIndexDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildPlaylist()
        }
    }

    // MARK: - 数据源

    /**
     * 重建播放列表（对应 Android observePlaylist collect）。
     * 仅当路径集合真正变化时才重建排序，避免 lastPlayedAt 更新
     * 触发通知导致 RANDOM 模式重新洗牌。
     */
    private func rebuildPlaylist() {
        // 后台读取，主线程回调（通知在主线程，DB 读串行队列很快，直接同步读取亦可；
        // 但 getCachedPhotos 走串行队列 sync，大库时避免卡主线程，放 utility）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let cached = self.photoRepository.getCachedPhotos()
            DispatchQueue.main.async {
                self.applyCached(cached)
            }
        }
    }

    private func applyCached(_ cached: [PhotoIndexEntity]) {
        if cached.isEmpty {
            playlist = []
            currentPath = nil
            // 触发后台下载
            scanCoordinator.downloadNow()
            state = settings.isConfigured ? .loading : .empty(reason: "请先在设置中连接 NAS")
            return
        }

        // 仅当路径集合真正变化时才重建播放列表
        let newPaths = Set(cached.map { $0.fullPath })
        let oldPaths = Set(playlist.map { $0.fullPath })
        if newPaths == oldPaths, !playlist.isEmpty {
            // 路径集合未变，仅同步字段（保留顺序，避免 RANDOM 重新洗牌）
            let map = Dictionary(uniqueKeysWithValues: cached.map { ($0.fullPath, $0) })
            playlist = playlist.map { map[$0.fullPath] ?? $0 }
            return
        }

        playlist = sortByPlayOrder(cached)

        // 定位当前张：优先保留锚点
        let anchor = currentPath
        let wasEmpty = (anchor == nil)
        if let anchor = anchor,
           let idx = playlist.firstIndex(where: { $0.fullPath == anchor }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }

        // 首次加载到照片时自动开播
        if wasEmpty, !playlist.isEmpty, !playing {
            playing = true
            emitCurrent(keepPlayingState: true)
            startTicker()
        } else {
            emitCurrent(keepPlayingState: playing)
        }
    }

    private func sortByPlayOrder(_ list: [PhotoIndexEntity]) -> [PhotoIndexEntity] {
        switch settings.getPlayOrder() {
        case .random: return list.shuffled()
        case .sequential: return list.sorted { $0.fullPath < $1.fullPath }
        case .timeDesc: return list.sorted { $0.lastModified > $1.lastModified }
        case .timeAsc: return list.sorted { $0.lastModified < $1.lastModified }
        }
    }

    // MARK: - 播放控制

    func play() {
        guard !playlist.isEmpty else { return }
        playing = true
        emitCurrent(keepPlayingState: true)
        startTicker()
    }

    func pause() {
        playing = false
        emitCurrent(keepPlayingState: false)
        stopTicker()
    }

    func toggle() {
        playing ? pause() : play()
    }

    /// 下一张（手动触发时重置定时器）
    func next() {
        guard !playlist.isEmpty else { return }
        currentIndex = (currentIndex + stepSize()) % playlist.count
        emitCurrent(keepPlayingState: playing)
        if playing { restartTicker() }
    }

    /// 上一张
    func prev() {
        guard !playlist.isEmpty else { return }
        let step = stepSize()
        currentIndex = ((currentIndex - step) % playlist.count + playlist.count) % playlist.count
        emitCurrent(keepPlayingState: playing)
        if playing { restartTicker() }
    }

    /// 回报上一页实际展示的不重复照片数（渲染完成后由 UI 调用）
    func onPageConsumed(_ count: Int) {
        lastPageConsumed = max(1, count)
    }

    /**
     * 每次推进的步长 = 上一页实际展示的照片数。
     * 上限为 size-1：若步长恰等于列表长度会整除卡死（同一页无限重复）；
     * 照片库过小时宁可跨页重叠，也不出现同页重复或卡死。
     */
    private func stepSize() -> Int {
        let size = playlist.count
        if size <= 1 { return 1 }
        return min(max(1, lastPageConsumed), size - 1)
    }

    // MARK: - 内部实现

    private func emitCurrent(keepPlayingState: Bool) {
        guard let item = playlist.indices.contains(currentIndex) ? playlist[currentIndex] : nil else {
            state = .empty(reason: "播放列表为空")
            return
        }
        currentPath = item.fullPath
        let localFile = cacheManager.localFileFor(fullPath: item.fullPath)
        let upcoming = resolveUpcoming()
        let videoFile = cacheManager.findLiveVideo(photo: item)

        state = keepPlayingState
            ? .playing(current: item, localFile: localFile, index: currentIndex,
                       total: playlist.count, upcoming: upcoming, videoFile: videoFile)
            : .paused(current: item, localFile: localFile, index: currentIndex,
                      total: playlist.count, upcoming: upcoming, videoFile: videoFile)

        // 异步更新 LRU 时间戳
        let path = item.fullPath
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.photoRepository.updatePlayedTime(fullPath: path)
        }
    }

    /// 取当前照片之后的若干张（拼贴/分屏/九宫格使用，不与当前张重复，携带 NAS 拍摄时间）
    private func resolveUpcoming(count: Int = 8) -> [UpcomingPhoto] {
        if playlist.count <= 1 { return [] }
        var result: [UpcomingPhoto] = []
        result.reserveCapacity(count)
        var offset = 1
        while result.count < count, offset < playlist.count {
            let next = playlist[(currentIndex + offset) % playlist.count]
            result.append(UpcomingPhoto(
                file: cacheManager.localFileFor(fullPath: next.fullPath),
                timeMs: next.lastModified
            ))
            offset += 1
        }
        return result
    }

    // MARK: - 自动推进定时器

    private func startTicker() {
        stopTicker()
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// 半秒心跳：到达设定间隔时推进（间隔变更即时生效）
    private var elapsedSinceAdvance: TimeInterval = 0
    private var lastTickAt: Date?

    private func tick() {
        guard playing, !playlist.isEmpty else { return }
        let now = Date()
        if let last = lastTickAt {
            elapsedSinceAdvance += now.timeIntervalSince(last)
        }
        lastTickAt = now
        let interval = TimeInterval(settings.getPlayIntervalMs()) / 1000.0
        if elapsedSinceAdvance >= interval {
            elapsedSinceAdvance = 0
            currentIndex = (currentIndex + stepSize()) % playlist.count
            emitCurrent(keepPlayingState: true)
        }
    }

    private func restartTicker() {
        elapsedSinceAdvance = 0
        lastTickAt = Date()
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
        elapsedSinceAdvance = 0
        lastTickAt = nil
    }
}
