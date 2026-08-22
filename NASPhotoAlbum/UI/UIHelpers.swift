import UIKit
import ImageIO

// MARK: - 通用工具

/// UIColor 便捷构造：ARGB 整数（与 Android 端 0xAARRGGBB 一致）
extension UIColor {
    convenience init(argb: Int) {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

/// 字节数格式化为 "1.5 GB" 等人类可读文本
func formatSize(_ bytes: Int64) -> String {
    if bytes <= 0 { return "0 B" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var size = Double(bytes)
    var idx = 0
    while size >= 1024 && idx < units.count - 1 {
        size /= 1024
        idx += 1
    }
    return String(format: "%.1f %@", size, units[idx])
}

// MARK: - 渐变视图

/// 单向线性渐变视图（用于暗角/遮幅过渡/胶片颗粒等装饰）
final class GradientView: UIView {
    convenience init(colors: [UIColor], startPoint: CGPoint, endPoint: CGPoint) {
        self.init(frame: .zero)
        let layer = self.layer as! CAGradientLayer
        layer.colors = colors.map { $0.cgColor }
        layer.startPoint = startPoint
        layer.endPoint = endPoint
    }

    override class var layerClass: AnyClass { return CAGradientLayer.self }
}

// MARK: - 线性布局容器

/**
 * 简易权重线性布局（等价 Android LinearLayout weight）。
 * 手动 layoutSubviews 计算帧，避免 Auto Layout 多视图约束开销，
 * 保证拼贴/分屏/九宫格等比例布局在 iPad mini 2 上流畅。
 */
final class LinearLayout: UIView {
    enum Axis { case horizontal, vertical }

    var axis: Axis
    var spacing: CGFloat = 0
    var padding: UIEdgeInsets = .zero
    /// 子视图权重（与 addSubview 配套记录），全部为 0 时均分
    private var weights: [CGFloat] = []
    private var children: [UIView] = []

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /** 添加子视图并指定权重（0 表示按内容压缩/固定尺寸） */
    func addWeighted(_ child: UIView, weight: CGFloat) {
        children.append(child)
        weights.append(weight)
        addSubview(child)
        setNeedsLayout()
    }

    /// 添加固定尺寸子视图（沿主轴固定，交叉轴填满）
    func addFixed(_ child: UIView, size: CGFloat) {
        children.append(child)
        weights.append(-size - 1000) // 负值编码固定尺寸：-(size+1000)
        addSubview(child)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = self.bounds
        let inner = CGRect(
            x: bounds.minX + padding.left,
            y: bounds.minY + padding.top,
            width: bounds.width - padding.left - padding.right,
            height: bounds.height - padding.top - padding.bottom
        )
        let totalSpacing = spacing * CGFloat(max(0, children.count - 1))

        let isHorizontal = (axis == .horizontal)
        let mainLen = isHorizontal ? inner.width : inner.height
        let crossLen = isHorizontal ? inner.height : inner.width

        // 主轴分配：固定尺寸 + 权重
        var fixedTotal: CGFloat = 0
        var weightTotal: CGFloat = 0
        for w in weights {
            if w < -900 { fixedTotal += (-w - 1000) } else { weightTotal += w }
        }
        let weightedAvailable = max(0, mainLen - totalSpacing - fixedTotal)

        var offset: CGFloat = isHorizontal ? inner.minX : inner.minY
        for (i, child) in children.enumerated() {
            let w = weights[i]
            let mainSize: CGFloat
            if w < -900 {
                mainSize = (-w - 1000)
            } else if weightTotal > 0 {
                mainSize = weightedAvailable * (w / weightTotal)
            } else {
                mainSize = weightedAvailable / CGFloat(max(1, weights.count))
            }
            let frame = isHorizontal
                ? CGRect(x: offset, y: inner.minY, width: mainSize, height: crossLen)
                : CGRect(x: inner.minX, y: offset, width: crossLen, height: mainSize)
            child.frame = frame
            offset += mainSize + spacing
        }
    }
}

// MARK: - 图片加载（降采样，低内存）

/**
 * 图片加载器（替代 Android 端 Glide）。
 *
 * iPad mini 2 仅 1GB 内存：
 * - 用 ImageIO 缩略图接口按 maxPixel 降采样解码，绝不明文解码整张原图（防 OOM / 内存峰值）
 * - NSCache 限额 24 张 / 约 120MB 像素成本，命中直接回调
 * - 解码在后台队列，回调统一切主线程
 */
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache: NSCache<NSString, UIImage>
    private let queue = DispatchQueue(label: "nasphotoalbum.imageio", qos: .userInitiated)

    init() {
        cache = NSCache()
        cache.countLimit = 24
        cache.totalCostLimit = 120 * 1024 * 1024
    }

    /// 计算像素内存成本（RGBA 4 字节）
    private static func cost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return cg.width * cg.height * 4
        }
        return 0
    }

    /**
     * 异步加载本地图片（降采样到 maxPixel）。
     * @param maxPixel 长边最大像素（默认 1600，覆盖 iPad mini 2 全屏 Retina）
     */
    func load(
        file: URL,
        maxPixel: CGFloat = 1600,
        completion: @escaping (UIImage?) -> Void
    ) {
        let key = "\(file.path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) {
            DispatchQueue.main.async { completion(hit) }
            return
        }
        queue.async { [weak self] in
            guard let self = self else { return }
            let image = self.decode(file: file, maxPixel: maxPixel)
            if let image = image {
                self.cache.setObject(image, forKey: key, cost: ImageLoader.cost(of: image))
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// 预热（人脸检测等需要立即显示的场景）
    private func decode(file: URL, maxPixel: CGFloat) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let src = CGImageSourceCreateWithURL(file as CFURL, options as CFDictionary) else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // 含 EXIF 旋转
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(
            src, 0, thumbOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - 描边文本标签

/**
 * 支持描边的文本标签（对应 Android 端 StrokeTextView）。
 * 通过 NSAttributedString 的负描边宽度实现"填充 + 描边"。
 */
final class StrokeLabel: UILabel {
    var strokeEnabled: Bool = false
    var strokeUIColor: UIColor = .black
    var strokeWidthRatio: CGFloat = -3.0 // 负值 = 描边并填充

    override func drawText(in rect: CGRect) {
        if !strokeEnabled {
            super.drawText(in: rect)
            return
        }
        let attrText = attributedText ?? NSAttributedString(
            string: text ?? "", attributes: [.font: font as Any, .foregroundColor: textColor as Any]
        )
        let stroked = NSMutableAttributedString(attributedString: attrText)
        let range = NSRange(location: 0, length: stroked.length)
        stroked.addAttribute(.strokeColor, value: strokeUIColor, range: range)
        stroked.addAttribute(.strokeWidth, value: strokeWidthRatio, range: range)
        stroked.draw(in: rect)
    }
}
