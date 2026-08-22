import Foundation
import AMSMB2

/**
 * SMB 客户端封装（基于 AMSMB2 2.7.1，对应 Android 端 smbj 的 SmbClient）。
 *
 * 设计要点（与 Android 端一致）：
 * 1. 每次操作建立独立连接，操作完成后断开，避免线程安全问题。
 * 2. 所有方法返回 Result，便于上层区分错误。
 * 3. 路径分隔符统一使用正斜杠 `/`，共享内路径不携带共享名前缀。
 * 4. 所有方法为同步阻塞调用，调用方必须放后台队列。
 *
 * AMSMB2 2.7.1 API 兼容性说明：
 * 本文件只依赖以下 5 个 AMSMB2 入口（均为 2.x 稳定 API）：
 *   AMSMB2(url:credential:) / connectShare(name:timeout:) / listShares(timeout:)
 *   contentsOfDirectory(atPath:) / downloadFile(atPath:to:progress:)
 * 若所装版本的方法签名略有出入（1.x→2.x 期间有过重命名），
 * 按编译器提示微调本文件的这几行即可，其余代码不受影响。
 */
final class SMBClient {

    /// 连接超时（秒）
    private let connectTimeout: TimeInterval = 10

    // MARK: - 对外操作（Result 风格，与 Android 端一一对应）

    /** 测试连接是否可用 */
    func testConnection(_ config: SmbConfig) -> Result<Void, Error> {
        guard config.isValid else {
            return .failure(NSError(domain: "SMBClient", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "NAS 配置不完整"]))
        }
        do {
            let client = try connect(config: config, shareName: config.shareName.isEmpty ? nil : config.shareName)
            finish(client)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /** 列出 NAS 上所有共享名 */
    func listShares(_ config: SmbConfig) -> Result<[String], Error> {
        guard config.isValid else {
            return .failure(NSError(domain: "SMBClient", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "NAS 配置不完整"]))
        }
        do {
            let client = try connect(config: config, shareName: nil)
            defer { finish(client) }
            let shares = try client.listShares(timeout: connectTimeout)
            return .success(shares.map { $0.name })
        } catch {
            return .failure(error)
        }
    }

    /** 列出指定路径下的子目录（不包含文件） */
    func listDirectories(
        _ config: SmbConfig,
        shareName: String,
        path: String
    ) -> Result<[NasDirNode], Error> {
        guard config.isValid else {
            return .failure(NSError(domain: "SMBClient", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "NAS 配置不完整"]))
        }
        guard !shareName.isEmpty else {
            return .failure(NSError(domain: "SMBClient", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "共享名不能为空"]))
        }
        do {
            let client = try connect(config: config, shareName: shareName)
            defer { finish(client) }
            let nodes = listEntries(client: client, path: path).filter { $0.isDirectory }
            return .success(nodes.sorted { $0.name < $1.name })
        } catch {
            return .failure(error)
        }
    }

    /** 列出指定路径下的所有文件（含子目录，用于扫描） */
    func listFiles(
        _ config: SmbConfig,
        shareName: String,
        path: String,
        recursive: Bool = false
    ) -> Result<[NasDirNode], Error> {
        guard config.isValid else {
            return .failure(NSError(domain: "SMBClient", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "NAS 配置不完整"]))
        }
        guard !shareName.isEmpty else {
            return .failure(NSError(domain: "SMBClient", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "共享名不能为空"]))
        }
        do {
            let client = try connect(config: config, shareName: shareName)
            defer { finish(client) }
            var result: [NasDirNode] = []
            collectFiles(client: client, path: path, recursive: recursive, out: &result)
            return .success(result)
        } catch {
            return .failure(error)
        }
    }

    /** 下载远程文件到本地路径 */
    func downloadFile(
        _ config: SmbConfig,
        shareName: String,
        path: String,
        to destURL: URL
    ) -> Result<Void, Error> {
        guard config.isValid else {
            return .failure(NSError(domain: "SMBClient", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "NAS 配置不完整"]))
        }
        guard !shareName.isEmpty else {
            return .failure(NSError(domain: "SMBClient", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "共享名不能为空"]))
        }
        do {
            let client = try connect(config: config, shareName: shareName)
            defer { finish(client) }
            // 确保父目录存在
            try FileManager.default.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try client.downloadFile(atPath: normalizeInner(path), to: destURL, progress: nil)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 内部实现

    /** 建立 SMB 连接并打开共享（shareName 为 nil 时仅枚举共享，不打开具体共享） */
    private func connect(config: SmbConfig, shareName: String?) throws -> AMSMB2 {
        var host = config.host
        for prefix in ["smb://", "SMB://"] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        let urlText = "smb://\(host):\(config.port)"
        guard let serverURL = URL(string: urlText) else {
            throw NSError(domain: "SMBClient", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "NAS 地址无效：\(config.host)"])
        }
        let credential = URLCredential(
            user: config.username,
            password: config.password,
            persistence: .forSession
        )
        guard let client = AMSMB2(url: serverURL, credential: credential) else {
            throw NSError(domain: "SMBClient", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法创建 SMB 客户端"])
        }
        // 免共享名模式：仅验证服务器可达（listShares 场景在调用方处理）
        try client.connectShare(
            name: shareName ?? "IPC$",
            timeout: connectTimeout
        )
        return client
    }

    /** 断开共享（连接对象释放时也会自动断开，这里显式触发以尽早释放资源） */
    private func finish(_ client: AMSMB2) {
        client.disconnectShare { _ in }
    }

    /** 共享内路径规范化：去掉首部斜杠，根目录返回空串 */
    private func normalizeInner(_ path: String) -> String {
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return p
    }

    /** 列出一层目录下的所有条目（含文件和子目录） */
    private func listEntries(client: AMSMB2, path: String) -> [NasDirNode] {
        let inner = normalizeInner(path)
        guard let entries = try? client.contentsOfDirectory(atPath: inner) else { return [] }
        var results: [NasDirNode] = []
        for entry in entries {
            // 与 AMSMB2 官方 README 一致：通过 URLResourceKey 下标读取条目属性
            guard let name = entry[.nameKey] as? String else { continue }
            if name == "." || name == ".." { continue }
            let type = entry[.fileResourceTypeKey] as? URLFileResourceType
            let isDir = (type == URLFileResourceType.directory)
            let size = (entry[.fileSizeKey] as? NSNumber)?.int64Value ?? 0
            let modified = entry[.contentModificationDateKey] as? Date
            let modifiedMs = modified.map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let childPath = trimmed.isEmpty ? "/\(name)" : "/\(trimmed)/\(name)"
            results.append(NasDirNode(
                name: name,
                path: childPath,
                isDirectory: isDir,
                size: size,
                lastModified: modifiedMs
            ))
        }
        return results
    }

    /** 递归收集文件 */
    private func collectFiles(client: AMSMB2, path: String, recursive: Bool, out: inout [NasDirNode]) {
        let entries = listEntries(client: client, path: path)
        for entry in entries {
            if entry.isDirectory {
                if recursive {
                    collectFiles(client: client, path: entry.path, recursive: recursive, out: &out)
                }
            } else {
                out.append(entry)
            }
        }
    }
}
