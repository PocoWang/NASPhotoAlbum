import Foundation
import SQLite3

/**
 * 照片索引数据库（SQLite3 封装）。
 *
 * 对应 Android 端 Room 的 AppDatabase + PhotoIndexDao：
 * - photo_index 表结构与 Room 版本完全一致（fullPath 主键）
 * - 所有方法同步执行在内部串行队列上，调用方自行放后台线程
 * - 任何写操作后通过 NotificationCenter 广播 photoIndexDidChange，
 *   UI 层据此重查统计（等价于 Room 的 Flow 失效追踪）
 */
final class Database {

    /// 索引变化通知（主线程发出）
    static let photoIndexDidChange = Notification.Name("photoIndexDidChange")

    /// SQLITE_TRANSIENT：让 sqlite 拷贝绑定的字符串
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let queue = DispatchQueue(label: "nasphotoalbum.db.photoindex")
    private var db: OpaquePointer?
    private let dbURL: URL

    init() {
        let fm = FileManager.default
        let supportDir = fm
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("NASPhotoAlbum", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        dbURL = supportDir.appendingPathComponent(AppConstants.dbName)

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            NSLog("Database open failed: %@", message)
            db = nil
            abort() // 索引库不可用属于致命错误，与 Room fallbackToDestructiveMigration 的兜底语义一致
        }
        db = handle
        queue.sync { createTableIfNeeded() }
    }

    deinit {
        if let db = db { sqlite3_close(db) }
    }

    // MARK: - 建表

    private func createTableIfNeeded() {
        execute("""
        CREATE TABLE IF NOT EXISTS photo_index (
            fullPath TEXT PRIMARY KEY NOT NULL,
            shareName TEXT NOT NULL,
            fileName TEXT NOT NULL,
            parentPath TEXT NOT NULL,
            sizeBytes INTEGER NOT NULL,
            lastModified INTEGER NOT NULL,
            extension TEXT NOT NULL,
            indexedAt INTEGER NOT NULL,
            isCached INTEGER NOT NULL DEFAULT 0,
            localCachePath TEXT,
            lastPlayedAt INTEGER NOT NULL DEFAULT 0,
            isLivePhoto INTEGER NOT NULL DEFAULT 0,
            pairedVideoPath TEXT,
            videoSizeBytes INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS index_photo_index_isCached ON photo_index(isCached);
        CREATE INDEX IF NOT EXISTS index_photo_index_lastPlayedAt ON photo_index(lastPlayedAt);
        CREATE INDEX IF NOT EXISTS index_photo_index_lastModified ON photo_index(lastModified);
        """)
    }

    // MARK: - 查询

    /// 所有照片（按拍摄时间倒序）
    func getAll() -> [PhotoIndexEntity] {
        return queue.sync {
            query("SELECT * FROM photo_index ORDER BY lastModified DESC", bind: nil)
        }
    }

    /// 已缓存照片（按最近播放时间倒序，用于 LRU）
    func getCachedPhotos() -> [PhotoIndexEntity] {
        return queue.sync {
            query("SELECT * FROM photo_index WHERE isCached = 1 ORDER BY lastPlayedAt DESC", bind: nil)
        }
    }

    /// 未缓存照片（用于后台下载原图）
    func getUncachedPhotos() -> [PhotoIndexEntity] {
        return queue.sync {
            query("SELECT * FROM photo_index WHERE isCached = 0 ORDER BY lastModified DESC", bind: nil)
        }
    }

    /// 照片总数
    func count() -> Int {
        return intValue("SELECT COUNT(*) FROM photo_index")
    }

    /// 已缓存照片数
    func cachedCount() -> Int {
        return intValue("SELECT COUNT(*) FROM photo_index WHERE isCached = 1")
    }

    /// 已缓存原图总大小（字节，含实况视频，计入缓存配额）
    func getTotalCachedSize() -> Int64 {
        return queue.sync {
            var out: Int64 = 0
            let sql = "SELECT COALESCE(SUM(sizeBytes + videoSizeBytes), 0) FROM photo_index WHERE isCached = 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                out = sqlite3_column_int64(stmt, 0)
            }
            return out
        }
    }

    /// 已识别为实况照片的数量
    func livePhotoCount() -> Int {
        return intValue("SELECT COUNT(*) FROM photo_index WHERE isLivePhoto = 1")
    }

    // MARK: - 写入

    /// 批量插入或更新（按主键 fullPath 去重），事务包裹
    func upsertAll(_ photos: [PhotoIndexEntity]) {
        guard !photos.isEmpty else { return }
        queue.sync {
            execute("BEGIN TRANSACTION")
            let sql = """
            INSERT OR REPLACE INTO photo_index
            (fullPath, shareName, fileName, parentPath, sizeBytes, lastModified, extension,
             indexedAt, isCached, localCachePath, lastPlayedAt, isLivePhoto, pairedVideoPath, videoSizeBytes)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                execute("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for entity in photos {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, entity.fullPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, entity.shareName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, entity.fileName, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, entity.parentPath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 5, entity.sizeBytes)
                sqlite3_bind_int64(stmt, 6, entity.lastModified)
                sqlite3_bind_text(stmt, 7, entity.fileExtension, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 8, entity.indexedAt)
                sqlite3_bind_int(stmt, 9, entity.isCached ? 1 : 0)
                if let cachePath = entity.localCachePath {
                    sqlite3_bind_text(stmt, 10, cachePath, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }
                sqlite3_bind_int64(stmt, 11, entity.lastPlayedAt)
                sqlite3_bind_int(stmt, 12, entity.isLivePhoto ? 1 : 0)
                if let paired = entity.pairedVideoPath {
                    sqlite3_bind_text(stmt, 13, paired, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 13)
                }
                sqlite3_bind_int64(stmt, 14, entity.videoSizeBytes)
                sqlite3_step(stmt)
            }
            execute("COMMIT")
        }
        postChange()
    }

    /// 标记某照片已缓存
    func markCached(fullPath: String, localPath: String) {
        queue.sync {
            execute("UPDATE photo_index SET isCached = 1, localCachePath = '\(esc(localPath))' WHERE fullPath = '\(esc(fullPath))'")
        }
        postChange()
    }

    /// 标记某照片未缓存（同时重置实况标记与视频大小：视频文件已随原图删除）
    func markUncached(fullPath: String) {
        queue.sync {
            execute("UPDATE photo_index SET isCached = 0, localCachePath = NULL, isLivePhoto = 0, videoSizeBytes = 0 WHERE fullPath = '\(esc(fullPath))'")
        }
        postChange()
    }

    /// 标记实况视频已缓存（记录大小并标记为实况照片）
    func markVideoCached(fullPath: String, videoBytes: Int64) {
        queue.sync {
            execute("UPDATE photo_index SET isLivePhoto = 1, videoSizeBytes = \(videoBytes) WHERE fullPath = '\(esc(fullPath))'")
        }
        postChange()
    }

    /// 更新播放时间（LRU 依据）
    func updatePlayedTime(fullPath: String, timestamp: Int64) {
        queue.sync {
            execute("UPDATE photo_index SET lastPlayedAt = \(timestamp) WHERE fullPath = '\(esc(fullPath))'")
        }
        postChange()
    }

    /// 删除不在保留列表中的照片（用于扫描后清理已删除的），返回删除条数。
    /// 使用临时表保存白名单，规避 SQLite 绑定参数上限。
    @discardableResult
    func deleteNotIn(keepPaths: [String]) -> Int {
        return queue.sync {
            guard !keepPaths.isEmpty else {
                return executeChanges("DELETE FROM photo_index")
            }
            _ = execute("DROP TABLE IF EXISTS keep_paths")
            guard execute("CREATE TEMP TABLE keep_paths (k TEXT PRIMARY KEY NOT NULL)") else { return 0 }
            var insert: OpaquePointer?
            let insertSql = "INSERT OR IGNORE INTO keep_paths (k) VALUES (?1)"
            guard sqlite3_prepare_v2(db, insertSql, -1, &insert, nil) == SQLITE_OK else {
                _ = execute("DROP TABLE IF EXISTS keep_paths")
                return 0
            }
            defer { sqlite3_finalize(insert) }
            for path in keepPaths {
                sqlite3_reset(insert)
                sqlite3_bind_text(insert, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(insert)
            }
            let changes = executeChanges("DELETE FROM photo_index WHERE fullPath NOT IN (SELECT k FROM keep_paths)")
            _ = execute("DROP TABLE IF EXISTS keep_paths")
            if changes > 0 { postChange() }
            return changes
        }
    }

    /// 清空索引
    func clearAll() {
        queue.sync {
            _ = executeChanges("DELETE FROM photo_index")
        }
        postChange()
    }

    /// 重置所有照片的播放时间戳（用于"重置播放位置"）
    func resetAllPlayedTime() {
        queue.sync {
            _ = executeChanges("UPDATE photo_index SET lastPlayedAt = 0")
        }
        postChange()
    }

    /// 批量重置所有缓存标记（用于"清空缓存"），返回重置条数
    @discardableResult
    func clearAllCacheMarks() -> Int {
        return queue.sync {
            let changes = executeChanges("UPDATE photo_index SET isCached = 0, localCachePath = NULL, isLivePhoto = 0, videoSizeBytes = 0 WHERE isCached = 1")
            if changes > 0 { postChange() }
            return changes
        }
    }

    // MARK: - 内部工具

    private func postChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Database.photoIndexDidChange, object: nil)
        }
    }

    /// SQL 字符串转义（仅用于内部已知字符串，输入路径可能含引号）
    private func esc(_ s: String) -> String {
        return s.replacingOccurrences(of: "'", with: "''")
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err = err {
            NSLog("Database exec error: %s", String(cString: err))
            sqlite3_free(err)
        }
        return ok
    }

    @discardableResult
    private func executeChanges(_ sql: String) -> Int {
        guard execute(sql) else { return 0 }
        return Int(sqlite3_changes(db))
    }

    private func intValue(_ sql: String) -> Int {
        return queue.sync {
            var out = 0
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                out = Int(sqlite3_column_int64(stmt, 0))
            }
            return out
        }
    }

    private func query(_ sql: String, bind: ((OpaquePointer) -> Void)?) -> [PhotoIndexEntity] {
        var result: [PhotoIndexEntity] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            return result
        }
        defer { sqlite3_finalize(stmt) }
        if let bind = bind { bind(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let fullPath = columnText(stmt, 1)
            let shareName = columnText(stmt, 2)
            let fileName = columnText(stmt, 3)
            let parentPath = columnText(stmt, 4)
            let sizeBytes = sqlite3_column_int64(stmt, 5)
            let lastModified = sqlite3_column_int64(stmt, 6)
            let fileExtension = columnText(stmt, 7)
            let indexedAt = sqlite3_column_int64(stmt, 8)
            let isCached = sqlite3_column_int(stmt, 9) != 0
            let localCachePath: String? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
                ? nil : columnText(stmt, 10)
            let lastPlayedAt = sqlite3_column_int64(stmt, 11)
            let isLivePhoto = sqlite3_column_int(stmt, 12) != 0
            let pairedVideoPath: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL
                ? nil : columnText(stmt, 13)
            let videoSizeBytes = sqlite3_column_int64(stmt, 14)
            result.append(PhotoIndexEntity(
                fullPath: fullPath,
                shareName: shareName,
                fileName: fileName,
                parentPath: parentPath,
                sizeBytes: sizeBytes,
                lastModified: lastModified,
                fileExtension: fileExtension,
                indexedAt: indexedAt,
                isCached: isCached,
                localCachePath: localCachePath,
                lastPlayedAt: lastPlayedAt,
                isLivePhoto: isLivePhoto,
                pairedVideoPath: pairedVideoPath,
                videoSizeBytes: videoSizeBytes
            ))
        }
        return result
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
