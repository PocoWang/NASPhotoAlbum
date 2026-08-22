import Foundation

/**
 * 安卓"动态照片"（Motion Photo）内嵌视频提取器（对应 Android 端 MotionPhotoExtractor）。
 *
 * 背景：小米/三星/Pixel 等安卓手机的"动态照片"是单张 JPEG 文件，
 * 约 3 秒的 MP4 视频片段直接追加在 JPEG 数据末尾（规范由 XMP 元数据标记偏移，
 * 但视频起点必然是标准 MP4 box 头 "size + ftyp"）。
 *
 * 提取策略（启发式 + 双重校验，无需解析 XMP）：
 * 1. 在文件中搜索 MP4 特征四字节 "ftyp"（JPEG 压缩流中不含此序列）
 * 2. 校验 "ftyp" 前 4 字节（box size 字段）为合理的小值——真实 ftyp box
 *    仅 8~64 字节，JPEG 压缩数据中的偶发字节匹配几乎不可能同时满足
 * 3. 校验截取段包含 "moov"/"mdat" box 且长度 >= 50KB
 * 4. 视频起点 = box size 字段处，截取到文件尾写出为 .mp4
 *
 * 仅适用于 jpg/jpeg（HEIC 文件头本身就含 ftyp box，会误提取，不支持）。
 */
enum MotionPhotoExtractor {

    /// MP4 ftyp box 特征（ISO BMFF 容器标识）
    private static let ftyp: [UInt8] = [0x66, 0x74, 0x79, 0x70]

    /// MP4 必备 box（校验截取段确为完整视频）
    private static let moov: [UInt8] = Array("moov".utf8)
    private static let mdat: [UInt8] = Array("mdat".utf8)

    /// 最小有效视频长度：低于此值几乎不可能是实况片段（排除误匹配）
    private static let minVideoBytes = 50 * 1024

    /// ftyp box size 合理范围（真实 ftyp 是小 box；size=1 表示 64 位扩展长度，极少见，一并放行下限）
    private static let minFtypBoxSize = 1
    private static let maxFtypBoxSize = 64

    /**
     * 从动态照片 JPEG 中提取内嵌视频并写入 dest。
     *
     * @return true 提取成功（dest 已写入有效 MP4）；false 非动态照片或提取失败
     */
    static func extractVideo(from jpeg: URL, to dest: URL) -> Bool {
        guard let data = try? Data(contentsOf: jpeg) else { return false }
        let bytes = [UInt8](data)
        return extractVideo(fromBytes: bytes, to: dest)
    }

    /// 字节级实现（便于测试与复用）
    static func extractVideo(fromBytes bytes: [UInt8], to dest: URL) -> Bool {
        guard bytes.count >= minVideoBytes else { return false }

        guard let ftypIdx = indexOf(bytes, ftyp), ftypIdx >= 4 else {
            return false // 未找到，或 box size 字段不完整
        }

        // 校验 box size 字段（ftyp 前 4 字节大端无符号整数）：
        // 真实 ftyp box 是小 box（典型 16~32 字节），排除压缩数据中的偶发误匹配
        let boxSize = (Int(bytes[ftypIdx - 4]) << 24)
            | (Int(bytes[ftypIdx - 3]) << 16)
            | (Int(bytes[ftypIdx - 2]) << 8)
            | Int(bytes[ftypIdx - 1])
        guard boxSize >= minFtypBoxSize, boxSize <= maxFtypBoxSize else { return false }

        let start = ftypIdx - 4 // 含 4 字节 box size 头
        let slice = Array(bytes[start...])

        // 校验：截取段必须是完整 MP4（含 moov 或 mdat box）
        let hasBox = indexOf(slice, moov) != nil || indexOf(slice, mdat) != nil
        guard hasBox, slice.count >= minVideoBytes else { return false }

        let fm = FileManager.default
        try? fm.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try Data(slice).write(to: dest, options: .atomic)
            return true
        } catch {
            NSLog("动态照片视频提取失败：%@", error.localizedDescription)
            return false
        }
    }

    /// 朴素字节序列搜索，返回首次出现位置（未找到返回 nil）
    private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let lastStart = haystack.count - needle.count
        var i = 0
        while i <= lastStart {
            var j = 0
            while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }
}
