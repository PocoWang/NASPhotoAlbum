import Foundation

/// 全局常量定义（与 Android 端 Constants.kt 一致）。
enum AppConstants {

    /// SMB 协议默认端口
    static let smbDefaultPort = 445

    /// 支持的图片扩展名（小写）
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "heif", "bmp", "gif"]

    /// 实况照片配对视频扩展名（iOS Live Photo 的同名 .mov 等，不作为独立照片入索引）
    static let livePhotoVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    /// 尝试提取内嵌视频的照片格式（安卓各家"动态照片"：单张 JPEG 末尾附带 MP4 片段）
    static let motionPhotoExtensions: Set<String> = ["jpg", "jpeg"]

    /// 单次扫描最多读取的文件数（防止超大目录卡死）
    static let scanMaxFiles = 50000

    /// 缓存大小默认值（字节）：1GB
    static let defaultCacheSizeBytes: Int64 = 1 << 30

    /// 默认播放间隔（毫秒）：5 秒
    static let defaultPlayIntervalMs: Int64 = 5000

    /// 缓存目录名
    static let cacheDirName = "original_cache"

    /// 索引数据库文件名
    static let dbName = "nas_photo_index.db"

    /// 缓存安全阈值：达到此比例后停止下载（0.95 表示 95%）
    static let cacheSafeRatio = 0.95
}

// MARK: - 播放顺序

/// 播放顺序枚举。
enum PlayOrder: Int, CaseIterable {
    case random = 0        // 随机播放
    case sequential = 1    // 顺序播放
    case timeDesc = 2      // 最新优先
    case timeAsc = 3       // 最旧优先

    var display: String {
        switch self {
        case .random: return "随机播放"
        case .sequential: return "顺序播放"
        case .timeDesc: return "最新优先"
        case .timeAsc: return "最旧优先"
        }
    }

    static func fromValue(_ v: Int) -> PlayOrder {
        return PlayOrder(rawValue: v) ?? .random
    }
}

// MARK: - 过渡动画

/// 过渡动画枚举。
enum TransitionType: Int, CaseIterable {
    case fade = 0     // 淡入淡出
    case slide = 1    // 左右滑动
    case zoom = 2     // 缩放
    case none = 3     // 无动画

    var display: String {
        switch self {
        case .fade: return "淡入淡出"
        case .slide: return "左右滑动"
        case .zoom: return "缩放"
        case .none: return "无动画"
        }
    }

    static func fromValue(_ v: Int) -> TransitionType {
        return TransitionType(rawValue: v) ?? .fade
    }
}

// MARK: - 时钟样式

/// 时钟样式枚举。
enum ClockStyle: Int, CaseIterable {
    case digital = 0   // 数字时钟
    case analog = 1    // 模拟时钟（以数字兜底，与 Android 端一致）
    case minimal = 2   // 极简（仅时间无日期）
    case none = 3      // 不显示

    var display: String {
        switch self {
        case .digital: return "数字时钟"
        case .analog: return "模拟时钟"
        case .minimal: return "极简"
        case .none: return "不显示"
        }
    }

    static func fromValue(_ v: Int) -> ClockStyle {
        return ClockStyle(rawValue: v) ?? .digital
    }
}

// MARK: - 展示模式

/// 照片展示模式枚举。
/// 每页展示的照片数与推进步长由 SlideshowEngine 按模式与屏幕方向动态计算。
enum DisplayMode: Int, CaseIterable {
    case single = 0        // 单张全屏
    case kenBurns = 1      // 电影推拉
    case polaroid = 2      // 拍立得卡片
    case collage = 3       // 回忆拼贴
    case splitScreen = 4   // 分屏对比
    case filmstrip = 5     // 胶片连放
    case mosaic = 6        // 马赛克九宫格
    case cinematic = 7     // 电影遮幅
    case memories = 8      // iOS 回忆
    case random = 99       // 随机切换

    var display: String {
        switch self {
        case .single: return "单张全屏"
        case .kenBurns: return "电影推拉"
        case .polaroid: return "拍立得卡片"
        case .collage: return "回忆拼贴"
        case .splitScreen: return "分屏对比"
        case .filmstrip: return "胶片连放"
        case .mosaic: return "马赛克九宫格"
        case .cinematic: return "电影遮幅"
        case .memories: return "iOS回忆"
        case .random: return "随机切换"
        }
    }

    static func fromValue(_ v: Int) -> DisplayMode {
        return DisplayMode(rawValue: v) ?? .single
    }

    /// 所有具体可渲染的模式（不含 RANDOM）
    static var concreteModes: [DisplayMode] {
        return DisplayMode.allCases.filter { $0 != .random }
    }
}

// MARK: - 时钟外观

/// 时钟字体枚举。
enum ClockFont: Int, CaseIterable {
    case defaultBold = 0  // 默认粗体
    case serif = 1        // 衬线
    case monospace = 2    // 等宽
    case serifBold = 3    // 衬线粗体

    var display: String {
        switch self {
        case .defaultBold: return "默认粗体"
        case .serif: return "衬线"
        case .monospace: return "等宽"
        case .serifBold: return "衬线粗体"
        }
    }

    static func fromValue(_ v: Int) -> ClockFont {
        return ClockFont(rawValue: v) ?? .defaultBold
    }
}

/// 时钟阴影强度枚举。
enum ClockShadow: Int, CaseIterable {
    case none = 0
    case light = 1
    case deep = 2

    var display: String {
        switch self {
        case .none: return "无"
        case .light: return "轻微"
        case .deep: return "深邃"
        }
    }

    static func fromValue(_ v: Int) -> ClockShadow {
        return ClockShadow(rawValue: v) ?? .light
    }
}

// MARK: - 扫描周期

/// 扫描周期枚举。
enum ScanPeriod: Int, CaseIterable {
    case daily = 0
    case every3Days = 1
    case weekly = 2
    case monthly = 3
    case manualOnly = 4

    var display: String {
        switch self {
        case .daily: return "每天"
        case .every3Days: return "每 3 天"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .manualOnly: return "仅手动"
        }
    }

    /// 扫描间隔天数（-1 = 仅手动）
    var intervalDays: Int64 {
        switch self {
        case .daily: return 1
        case .every3Days: return 3
        case .weekly: return 7
        case .monthly: return 30
        case .manualOnly: return -1
        }
    }

    static func fromValue(_ v: Int) -> ScanPeriod {
        return ScanPeriod(rawValue: v) ?? .every3Days
    }
}

// MARK: - SMB 配置与领域模型

/// NAS SMB 连接配置。
struct SmbConfig: Equatable {
    var host: String
    var port: Int = AppConstants.smbDefaultPort
    var username: String
    var password: String
    var domain: String = ""
    var shareName: String = ""

    /// 是否已填写必要字段
    var isValid: Bool { !host.isEmpty && !username.isEmpty }
}

/// NAS 上的目录/文件节点。
struct NasDirNode {
    var name: String
    var path: String          // 正斜杠分隔，如 "/photo/2024"
    var isDirectory: Bool
    var size: Int64 = 0
    var lastModified: Int64 = 0

    /// 父目录路径
    var parentPath: String {
        if path == "/" || path.isEmpty { return "/" }
        var t = path
        while t.count > 1 && t.hasSuffix("/") { t.removeLast() }
        if let idx = t.lastIndex(of: "/") {
            if idx == t.startIndex { return "/" }
            return String(t[t.startIndex..<idx])
        }
        return "/"
    }

    /// 文件扩展名（小写，无点），目录返回空
    var `extension`: String {
        if isDirectory { return "" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }
}

/// 扫描结果统计。
struct ScanResult {
    var added: Int
    var removed: Int
    var unchanged: Int

    var total: Int { added + unchanged }
    var hasChange: Bool { added > 0 || removed > 0 }
}
