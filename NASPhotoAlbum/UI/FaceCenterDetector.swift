import Foundation
import ImageIO
import CoreImage

/**
 * 人脸中心检测器（对应 Android 端 StageRenderer 内置的 FaceDetector 管线）。
 *
 * iOS 端用 CoreImage CIDetector 替代 android.media.FaceDetector：
 * - 缩略图解码（长边 480px）兼顾 A7 芯片速度与多脸精度
 * - 按 EXIF 方向传入 CIDetectorImageOrientation，竖拍照片"先转正再检测"，
 *   与 Android 端"先旋转位图再检测"语义一致
 * - 多脸按人脸框面积平方加权质心（近似 Android 眼距平方权重，大脸=主体权重高）
 * - 误检过滤：人脸框最小边 < 短边 8% 的丢弃（近似眼距 < 短边 4%）
 * - 构图微调：质心略上移（cy × 0.90）
 * - LRU 缓存（上限 256）+ 负缓存（无人脸也记录，避免重复检测）
 * - 单线程串行执行 + 同文件并发请求合并
 *
 * 返回归一化坐标 (0~1, 0~1)，原点为图片左上角（显示坐标系）。
 */
final class FaceCenterDetector {

    static let shared = FaceCenterDetector()

    typealias FacePoint = (x: Float, y: Float)

    /// LRU 缓存：key = 文件路径；value nil 表示已检测但无人脸（负缓存）
    private var cache: [String: FacePoint?] = [:]
    private var order: [String] = [] // 访问序，越靠后越新
    private let cacheLimit = 256
    private let lock = NSLock()

    /// 串行检测队列（避免多图并发解码造成内存峰值）
    private let detectQueue = DispatchQueue(label: "nasphotoalbum.face", qos: .utility)

    /// 检测在途的文件 → 等待回调列表（同一文件并发请求合并为一次检测）
    private var pending: [String: [(FacePoint?) -> Void]] = [:]
    private let pendingLock = NSLock()

    private lazy var detector: CIDetector? = {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        return CIDetector(
            ofType: CIDetectorTypeFace,
            context: context,
            options: [
                CIDetectorAccuracy: CIDetectorAccuracyLow, // A7 上 low 已足够定位质心
                CIDetectorTracking: false
            ]
        )
    }()

    private init() {}

    // MARK: - 缓存查询

    /// 查询已缓存的人脸中心（未检测过返回 nil，不触发检测）
    func faceCenterIfDetected(file: URL) -> FacePoint? {
        lock.lock(); defer { lock.unlock() }
        return cache[file.path] ?? nil
    }

    /// 是否已检测过（含"检测了但无人脸"的负缓存）
    func isDetected(file: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cache[file.path] != nil
    }

    // MARK: - 异步检测

    /**
     * 异步获取人脸中心：缓存命中立即回调（主线程），否则后台检测后回调。
     * 同一文件并发调用时挂入待回调列表，检测一次、全部回调。
     */
    func faceCenterAsync(file: URL, onResult: @escaping (FacePoint?) -> Void) {
        let path = file.path
        lock.lock()
        if let cached = cache[path] {
            touch(path)
            lock.unlock()
            DispatchQueue.main.async { onResult(cached) }
            return
        }
        lock.unlock()

        pendingLock.lock()
        if var waiting = pending[path] {
            waiting.append(onResult)
            pending[path] = waiting
            pendingLock.unlock()
            return
        }
        pending[path] = [onResult]
        pendingLock.unlock()

        detectQueue.async { [weak self] in
            let result = self?.detectSync(file: file) ?? nil
            guard let self = self else { return }

            self.lock.lock()
            self.cache[path] = result
            self.touch(path)
            self.lock.unlock()

            self.pendingLock.lock()
            let callbacks = self.pending.removeValue(forKey: path) ?? []
            self.pendingLock.unlock()

            DispatchQueue.main.async {
                for cb in callbacks { cb(result) }
            }
        }
    }

    /// LRU 访问序维护
    private func touch(_ path: String) {
        if let idx = order.firstIndex(of: path) { order.remove(at: idx) }
        order.append(path)
        while order.count > cacheLimit {
            let eldest = order.removeFirst()
            cache.removeValue(forKey: eldest)
        }
    }

    // MARK: - 同步检测

    /// 同步检测（仅在 detectQueue 上调用）
    private func detectSync(file: URL) -> FacePoint? {
        guard let src = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }

        // 缩略图解码（480px），保留 EXIF 方向
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false, // 不旋转，方向交给 CIDetector
            kCGImageSourceThumbnailMaxPixelSize: 480
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let w = cg.width
        let h = cg.height
        if w < 8 || h < 8 { return nil }

        // EXIF 方向（1~8），CIDetectorImageOrientation 直接采用同值
        let orient = imageOrientation(of: src)

        guard let detector = detector else { return nil }
        let ci = CIImage(cgImage: cg)
        let options: [String: Any] = [CIDetectorImageOrientation: orient.rawValue]
        let faces = detector.features(in: ci, options: options)
        guard !faces.isEmpty else { return nil }

        // 面积平方加权质心：大脸（主体）权重大，合影整组居中。
        // CI 坐标系原点在左下，先翻转到左上原点的显示坐标系。
        let minSide = CGFloat(min(w, h))
        let minFaceSide = minSide * 0.08 // 近似 Android：眼距 < 短边 4%（眼距≈脸宽/2）
        var weightSum: CGFloat = 0
        var xSum: CGFloat = 0
        var ySum: CGFloat = 0
        for f in faces {
            guard let face = f as? CIFaceFeature else { continue }
            let box = face.bounds
            let side = min(box.width, box.height)
            if side < minFaceSide { continue }
            let cx = box.midX
            let cyTopLeft = CGFloat(h) - box.midY
            let weight = box.width * box.height // 面积权重（≈眼距²的常数倍）
            xSum += cx * weight
            ySum += cyTopLeft * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return nil }

        var fx = Float(xSum / weightSum / CGFloat(w))
        var fy = Float(ySum / weightSum / CGFloat(h))
        // 构图微调：人脸中心略上移，给身体留空间
        fy = min(max(fy * 0.90, 0.05), 0.95)
        fx = min(max(fx, 0.05), 0.95)
        return (fx, fy)
    }

    private func imageOrientation(of src: CGImageSource) -> CGImagePropertyOrientation {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32,
              let orient = CGImagePropertyOrientation(rawValue: raw) else {
            return .up
        }
        return orient
    }
}
