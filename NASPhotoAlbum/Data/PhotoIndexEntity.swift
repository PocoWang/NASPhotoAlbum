import Foundation

/**
 * 照片索引实体（与 Android 端 PhotoIndexEntity 一比一对应）。
 *
 * 一条记录对应 NAS 上的一张照片文件。
 * fullPath 作为主键，唯一标识一张照片。
 */
struct PhotoIndexEntity {

    /// 完整路径，如 "/photo/2024/IMG_001.jpg"（主键）
    var fullPath: String
    /// 所属共享名
    var shareName: String
    /// 文件名，如 "IMG_001.jpg"
    var fileName: String
    /// 父目录路径（共享内路径），如 "/2024"
    var parentPath: String
    /// 文件大小（字节）
    var sizeBytes: Int64
    /// NAS 上的最后修改时间戳（毫秒）
    var lastModified: Int64
    /// 扩展名（小写），如 "jpg"
    var fileExtension: String
    /// 索引时间戳（毫秒）
    var indexedAt: Int64
    /// 原图是否已下载到本地缓存
    var isCached: Bool
    /// 本地缓存文件路径（isCached=true 时非空）
    var localCachePath: String?
    /// 上次播放时间戳（用于 LRU 淘汰）
    var lastPlayedAt: Int64
    /// 是否为实况照片（iOS 同名 .mov 配对，或安卓动态照片内嵌视频提取成功）
    var isLivePhoto: Bool
    /// NAS 上配对视频文件的完整路径（iOS Live Photo 的 IMG_xxx.MOV）
    var pairedVideoPath: String?
    /// 已缓存的实况视频文件大小（字节，计入缓存配额；未缓存为 0）
    var videoSizeBytes: Int64

    init(
        fullPath: String,
        shareName: String,
        fileName: String,
        parentPath: String,
        sizeBytes: Int64,
        lastModified: Int64,
        fileExtension: String,
        indexedAt: Int64,
        isCached: Bool = false,
        localCachePath: String? = nil,
        lastPlayedAt: Int64 = 0,
        isLivePhoto: Bool = false,
        pairedVideoPath: String? = nil,
        videoSizeBytes: Int64 = 0
    ) {
        self.fullPath = fullPath
        self.shareName = shareName
        self.fileName = fileName
        self.parentPath = parentPath
        self.sizeBytes = sizeBytes
        self.lastModified = lastModified
        self.fileExtension = fileExtension
        self.indexedAt = indexedAt
        self.isCached = isCached
        self.localCachePath = localCachePath
        self.lastPlayedAt = lastPlayedAt
        self.isLivePhoto = isLivePhoto
        self.pairedVideoPath = pairedVideoPath
        self.videoSizeBytes = videoSizeBytes
    }
}
