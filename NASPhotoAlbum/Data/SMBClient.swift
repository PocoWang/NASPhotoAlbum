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
 * AMSMB2 2.7.1 API 说明（2.x 全为异步回调式，本文件用信号量包装为同步）：
 *   AMSMB2(url:domain:credential:)                                    — failable init
 *   connectShare(name:encrypted:completionHandler:)                   — (Error?) -> Void
 *   disconnectShare(gracefully:completionHandler:)                    — 参数均有默认值
 *   listShares(enumerateHidden:completionHandler:)                    — Result<[(name,comment)], Error>
 *   contentsOfDirectory(atPath:recursive:completionHandler:)          — Result<[[URLResourceKey: Any]], Error>
 *   contents(atPath:progress:completionHandler:)                      — Result<Data, Error>（整文件读入内存）
 *   timeout 属性（秒）在 connect 之前设置。
 */
final class SMBClient {

    /// 连接超时（秒）
    private let connectTimeout: TimeInterval = 10
    /// 单次操作（列目录/下载）超时（秒）
    private let operationTimeout: TimeInterval = 120

    // MARK: - 对外操作（Result 风格，与 Android 端一一对应）

    /** 测试连接是否可用 */
    func testConnection(_ config: SmbConfig) -> Result<Void, Error> {
        guard config.isValid else {
            return .failure(smbError(1, "NAS 配置不完整"))
        }
        guard let client = makeClient(config) else {
            return .failure(smbError(3, "NAS 地址无效：\(config.host)"))
        }
        if config.shareName.isEmpty {
            // 免共享名模式：listShares 内部会自动连接 IPC$ 枚举共享，成功即代表服务器+凭据可用
            let result: Result<Void, Error> = syncAwait(connectTimeout + 15) { done in
                client.listShares { result in
                    switch result {
                    case .success: done(.success(()))
                    case .failure(let e): done(.failure(e))
                    }
                }
            }
            client.disconnectShare()
            return result
        } else {
            let result = connect(client, share: config.shareName)
            client.disconnectShare()
            return result
        }
    }

    /** 列出 NAS 上所有共享名 */
    func listShares(_ config: SmbConfig) -> Result<[String], Error> {
        guard config.isValid else {
            return .failure(smbError(1, "NAS 配置不完整"))
        }
        guard let client = makeClient(config) else {
            return .failure(smbError(3, "NAS 地址无效：\(config.host)"))
        }
        defer { client.disconnectShare() }
        return syncAwait(connectTimeout + 15) { done in
            client.listShares { result in
                done(result.map { $0.map { $0.name } })
            }
        }
    }

    /** 列出指定路径下的子目录（不包含文件） */
    func listDirectories(
        _ config: SmbConfig,
        shareName: String,
        path: String
    ) -> Result<[NasDirNode], Error> {
        guard config.isValid else {
            return .failure(smbError(1, "NAS 配置不完整"))
        }
        guard !shareName.isEmpty else {
            return .failure(smbError(2, "共享名不能为空"))
        }
        guard let client = makeClient(config) else {
            return .failure(smbError(3, "NAS 地址无效：\(config.host)"))
        }
        let connResult = connect(client, share: shareName)
        if case .failure(let e) = connResult { return .failure(e) }
        defer { client.disconnectShare() }
        let nodes = listEntries(client: client, path: path).filter { $0.isDirectory }
        return .success(nodes.sorted { $0.name < $1.name })
    }

    /** 列出指定路径下的所有文件（含子目录，用于扫描） */
    func listFiles(
        _ config: SmbConfig,
        shareName: String,
        path: String,
        recursive: Bool = false
    ) -> Result<[NasDirNode], Error> {
        guard config.isValid else {
            return .failure(smbError(1, "NAS 配置不完整"))
        }
        guard !shareName.isEmpty else {
            return .failure(smbError(2, "共享名不能为空"))
        }
        guard let client = makeClient(config) else {
            return .failure(smbError(3, "NAS 地址无效：\(config.host)"))
        }
        let connResult = connect(client, share: shareName)
        if case .failure(let e) = connResult { return .failure(e) }
        defer { client.disconnectShare() }
        var result: [NasDirNode] = []
        collectFiles(client: client, path: path, recursive: recursive, out: &result)
        return .success(result)
    }

    /**
     * 下载远程文件到本地路径。
     * AMSMB2 2.7.1 无流式落盘 API，contents(atPath:) 整文件读入内存后写盘；
     * 照片单张一般 < 20MB，iPad mini 2（1GB 内存）瞬时占用可接受。
     */
    func downloadFile(
        _ config: SmbConfig,
        shareName: String,
        path: String,
        to destURL: URL
    ) -> Result<Void, Error> {
        guard config.isValid else {
            return .failure(smbError(1, "NAS 配置不完整"))
        }
        guard !shareName.isEmpty else {
            return .failure(smbError(2, "共享名不能为空"))
        }
        guard let client = makeClient(config) else {
            return .failure(smbError(3, "NAS 地址无效：\(config.host)"))
        }
        let connResult = connect(client, share: shareName)
        if case .failure(let e) = connResult { return .failure(e) }
        defer { client.disconnectShare() }

        let dlResult: Result<Data, Error> = syncAwait(operationTimeout) { done in
            client.contents(atPath: normalizeInner(path), progress: nil) { result in
                done(result)
            }
        }
        switch dlResult {
        case .failure(let e):
            return .failure(e)
        case .success(let data):
            do {
                // 确保父目录存在
                try FileManager.default.createDirectory(
                    at: destURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destURL, options: .atomic)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
    }

    // MARK: - 内部实现

    /** 生成统一域名的 NSError */
    private func smbError(_ code: Int, _ message: String) -> NSError {
        return NSError(domain: "SMBClient", code: code,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }

    /**
     * 信号量同步包装：把 AMSMB2 的异步回调变为同步 Result。
     * AMSMB2 回调在其内部队列执行，阻塞调用方线程不会死锁。
     * 超时后返回失败；迟到回调仅多 signal 一次信号量，无副作用。
     */
    private func syncAwait<T>(
        _ timeout: TimeInterval,
        _ body: (@escaping (Result<T, Error>) -> Void) -> Void
    ) -> Result<T, Error> {
        let sem = DispatchSemaphore(value: 0)
        var out: Result<T, Error>!
        body { result in
            out = result
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .failure(smbError(5, "SMB 操作超时"))
        }
        return out
    }

    /** 创建 AMSMB2 客户端（host 允许带 smb:// 前缀，domain 来自配置） */
    private func makeClient(_ config: SmbConfig) -> AMSMB2? {
        var host = config.host
        for prefix in ["smb://", "SMB://"] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        guard let serverURL = URL(string: "smb://\(host):\(config.port)") else { return nil }
        let credential = URLCredential(
            user: config.username,
            password: config.password,
            persistence: .forSession
        )
        let client = AMSMB2(url: serverURL, domain: config.domain, credential: credential)
        client?.timeout = connectTimeout
        return client
    }

    /** 同步连接指定共享 */
    private func connect(_ client: AMSMB2, share: String) -> Result<Void, Error> {
        return syncAwait(connectTimeout + 5) { done in
            client.connectShare(name: share) { error in
                if let error = error {
                    done(.failure(error))
                } else {
                    done(.success(()))
                }
            }
        }
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
        let result: Result<[[URLResourceKey: Any]], Error> = syncAwait(operationTimeout) { done in
            client.contentsOfDirectory(atPath: inner) { result in
                done(result)
            }
        }
        guard case .success(let entries) = result else { return [] }
        var results: [NasDirNode] = []
        for entry in entries {
            // 与 AMSMB2 官方 README 一致：通过 URLResourceKey 下标读取条目属性
            guard let name = entry[.nameKey] as? String else { continue }
            if name == "." || name == ".." { continue }
            let type = entry[.fileResourceTypeKey] as? URLFileResourceType
            let isDir = (type == URLFileResourceType.directory)
            // fileSizeKey 为 Int64（含 NSNumber 桥接兜底）
            let size = (entry[.fileSizeKey] as? Int64)
                ?? (entry[.fileSizeKey] as? NSNumber)?.int64Value
                ?? 0
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
