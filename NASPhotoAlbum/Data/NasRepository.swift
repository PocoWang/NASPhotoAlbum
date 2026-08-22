import Foundation

/**
 * NAS 仓库：协调 SMBClient 与 SettingsStore（对应 Android 端 NasRepository）。
 *
 * - 对 UI 层提供领域方法，隐藏 SMB 协议细节。
 * - 所有方法为同步阻塞调用，须放后台队列执行。
 */
final class NasRepository {

    private let settings: SettingsStore
    private let smbClient: SMBClient

    init(settings: SettingsStore, smbClient: SMBClient) {
        self.settings = settings
        self.smbClient = smbClient
    }

    // MARK: - 配置读取

    func getNasConfig() -> SmbConfig? { settings.getNasConfig() }

    var isConfigured: Bool { settings.isConfigured }

    func saveNasConfig(_ config: SmbConfig) { settings.saveNasConfig(config) }

    func getSelectedDirs() -> Set<String> { settings.getSelectedDirs() }

    func setSelectedDirs(_ dirs: Set<String>) { settings.setSelectedDirs(dirs) }

    var includeSubdir: Bool {
        get { settings.includeSubdir }
        set { settings.includeSubdir = newValue }
    }

    var shareName: String { settings.getNasConfig()?.shareName ?? "" }

    // MARK: - SMB 操作

    /** 测试连接（可传入临时配置，用于设置页"测试连接"按钮） */
    func testConnection(_ config: SmbConfig) -> Result<Void, Error> {
        return smbClient.testConnection(config)
    }

    /** 列出 NAS 上所有共享名 */
    func listShares() -> Result<[String], Error> {
        guard let config = settings.getNasConfig() else {
            return .failure(NSError(domain: "NasRepository", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "未配置 NAS"]))
        }
        return smbClient.listShares(config)
    }

    /** 列出指定路径下的子目录 */
    func listDirectories(shareName: String, path: String) -> Result<[NasDirNode], Error> {
        guard let config = settings.getNasConfig() else {
            return .failure(NSError(domain: "NasRepository", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "未配置 NAS"]))
        }
        return smbClient.listDirectories(config, shareName: shareName, path: path)
    }

    /** 列出指定路径下的所有文件（可递归） */
    func listFiles(
        shareName: String,
        path: String,
        recursive: Bool = false
    ) -> Result<[NasDirNode], Error> {
        guard let config = settings.getNasConfig() else {
            return .failure(NSError(domain: "NasRepository", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "未配置 NAS"]))
        }
        return smbClient.listFiles(config, shareName: shareName, path: path, recursive: recursive)
    }

    /** 下载远程文件到本地 */
    func downloadFile(shareName: String, remotePath: String, to destURL: URL) -> Result<Void, Error> {
        guard let config = settings.getNasConfig() else {
            return .failure(NSError(domain: "NasRepository", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "未配置 NAS"]))
        }
        return smbClient.downloadFile(config, shareName: shareName, path: remotePath, to: destURL)
    }
}
