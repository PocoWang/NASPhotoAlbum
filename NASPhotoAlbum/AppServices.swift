import Foundation

/**
 * 全局服务定位器（单例容器）。
 *
 * 对应 Android 端由各组件自行构造的 Repository/CacheManager/WorkScheduler，
 * iOS 端统一持有，保证全局只初始化一份。
 */
final class AppServices {

    static let shared = AppServices()

    /// 偏好存储
    let settings: SettingsStore
    /// 照片索引数据库（SQLite）
    let database: Database
    /// SMB 客户端
    let smbClient: SMBClient
    /// NAS 仓库
    let nasRepository: NasRepository
    /// 照片仓库
    let photoRepository: PhotoRepository
    /// 缓存总管
    let cacheManager: CacheManager
    /// 扫描/下载协调器（替代 WorkManager）
    let scanCoordinator: ScanCoordinator

    private init() {
        let settings = SettingsStore()
        let database = Database()
        let smbClient = SMBClient()
        let nasRepository = NasRepository(settings: settings, smbClient: smbClient)
        let photoRepository = PhotoRepository(settings: settings, database: database, nasRepository: nasRepository)
        let cacheManager = CacheManager(settings: settings, photoRepository: photoRepository)
        let scanCoordinator = ScanCoordinator(
            settings: settings,
            photoRepository: photoRepository,
            nasRepository: nasRepository,
            cacheManager: cacheManager
        )
        self.settings = settings
        self.database = database
        self.smbClient = smbClient
        self.nasRepository = nasRepository
        self.photoRepository = photoRepository
        self.cacheManager = cacheManager
        self.scanCoordinator = scanCoordinator
    }
}
