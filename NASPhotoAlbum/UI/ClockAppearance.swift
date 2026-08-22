import UIKit

/**
 * 时钟容器视图：纵向堆叠时间/日期两个标签，按内容自适应尺寸。
 *
 * 覆写 sizeThatFits 使 UIView.sizeToFit() 能按标签内容计算大小
 * （默认 UIView.sizeToFit 不做任何事，会导致按比例定位拿不到真实宽高）。
 */
final class ClockOverlayView: UIView {

    private let lineGap: CGFloat = 4

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        var w: CGFloat = 0
        var h: CGFloat = 0
        for v in subviews where !v.isHidden {
            let s = v.sizeThatFits(size)
            w = max(w, s.width)
            h += s.height + lineGap
        }
        return CGSize(width: w + 4, height: max(0, h - lineGap))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var y: CGFloat = 0
        for v in subviews where !v.isHidden {
            let s = v.sizeThatFits(bounds.size)
            v.frame = CGRect(
                x: (bounds.width - s.width) / 2,
                y: y, width: s.width, height: s.height
            )
            y += s.height + lineGap
        }
    }
}

/**
 * 时钟外观渲染器（对应 Android 端 ClockAppearance）。
 *
 * 把 SettingsStore 中的时钟外观配置（字体/大小/颜色/阴影/描边/位置/样式）
 * 应用到时钟视图组，幻灯片播放页与设置页预览共用同一套逻辑，所见即所得。
 */
enum ClockAppearance {

    /// 时钟与屏幕边缘的间距（pt）
    private static let edgeMargin: CGFloat = 24

    /**
     * 应用外观。
     * @param overlay 时钟外层容器（由容器按比例定位）
     * @param clock   时间文本（StrokeLabel，支持描边）
     * @param date    日期文本
     */
    static func apply(
        store: SettingsStore,
        overlay: UIView,
        clock: StrokeLabel,
        date: UILabel
    ) {
        // ===== 样式（可见性） =====
        switch store.getClockStyle() {
        case .none:
            overlay.isHidden = true
            return
        case .minimal:
            overlay.isHidden = false
            date.isHidden = true
        default:
            // digital / analog（模拟样式以数字兜底，与 Android 一致）
            overlay.isHidden = false
            date.isHidden = false
        }

        // ===== 字体 =====
        switch store.getClockFont() {
        case .defaultBold:
            clock.font = .boldSystemFont(ofSize: clock.font.pointSize)
        case .serif:
            clock.font = UIFont(name: "Georgia", size: clock.font.pointSize)
                ?? .systemFont(ofSize: clock.font.pointSize)
        case .monospace:
            clock.font = UIFont(name: "CourierNewPSMT", size: clock.font.pointSize)
                ?? .systemFont(ofSize: clock.font.pointSize)
        case .serifBold:
            clock.font = UIFont(name: "Georgia-Bold", size: clock.font.pointSize)
                ?? .boldSystemFont(ofSize: clock.font.pointSize)
        }

        // ===== 大小 =====
        let sizePt = CGFloat(store.getClockSizeSp())
        clock.font = clock.font.withSize(sizePt)
        date.font = UIFont.systemFont(ofSize: max(12, sizePt * 0.32))

        // ===== 颜色 =====
        let color = UIColor(argb: store.getClockColor())
        clock.textColor = color
        date.textColor = color

        // ===== 阴影 =====
        func applyShadow(to label: UILabel, radius: CGFloat, x: CGFloat, y: CGFloat, alpha: Float) {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowRadius = radius
            label.layer.shadowOffset = CGSize(width: x, height: y)
            label.layer.shadowOpacity = alpha
            label.layer.masksToBounds = false
        }
        switch store.getClockShadow() {
        case .none:
            applyShadow(to: clock, radius: 0, x: 0, y: 0, alpha: 0)
            applyShadow(to: date, radius: 0, x: 0, y: 0, alpha: 0)
        case .light:
            applyShadow(to: clock, radius: 2, x: 1, y: 1, alpha: 0.5)
            applyShadow(to: date, radius: 1.5, x: 1, y: 1, alpha: 0.5)
        case .deep:
            applyShadow(to: clock, radius: 6, x: 2, y: 3, alpha: 0.7)
            applyShadow(to: date, radius: 3, x: 1, y: 2, alpha: 0.7)
        }

        // ===== 描边（仅时钟大字，日期小字描边会糊） =====
        clock.strokeEnabled = store.clockStrokeEnabled
        clock.strokeUIColor = UIColor(argb: store.getClockStrokeColor())
        clock.strokeWidthRatio = -max(1.0, sizePt * 0.055)

        // ===== 位置（绝对坐标比例） =====
        positionOverlay(overlay: overlay, in: overlay.superview, store: store, animated: false)
    }

    /**
     * 按比例定位时钟容器。
     * - 时钟中心点位于容器 (width * xRatio, height * yRatio)
     * - 先 sizeToFit 获得自身尺寸，再平移到目标位置并夹在容器内
     * - 容器尺寸未就绪时布局完成后再调用一次（layoutSubviews 回调）
     */
    static func positionOverlay(overlay: UIView, in container: UIView?, store: SettingsStore, animated: Bool) {
        guard let container = container ?? overlay.superview else { return }
        let (xRatio, yRatio) = store.getClockPositionRatio()

        let apply = {
            let cw = container.bounds.width
            let ch = container.bounds.height
            guard cw > 0, ch > 0 else { return }
            overlay.sizeToFit()
            let ow = overlay.bounds.width
            let oh = overlay.bounds.height
            // 中心点定位，并限制在容器内（留边距）
            let tx = min(max(cw * CGFloat(xRatio) - ow / 2, edgeMargin), cw - ow - edgeMargin)
            let ty = min(max(ch * CGFloat(yRatio) - oh / 2, edgeMargin), ch - oh - edgeMargin)
            overlay.frame.origin = CGPoint(x: max(0, tx), y: max(0, ty))
        }

        if animated {
            UIView.animate(withDuration: 0.25, animations: apply)
        } else {
            apply()
        }
    }
}
