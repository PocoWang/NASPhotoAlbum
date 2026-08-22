import UIKit

/**
 * 经典 DV 摄像机橙色拍摄日期戳（对应 Android 端 addCamcorderDateStamp）。
 *
 * 1:1 复刻 90 年代末~00 年代家用 DV 的 OSD 效果：
 * - 经典橙 #FF7F27
 * - 两行布局：上行 "2005.01.31"，下行 "PM 3:45"（12 小时制，0 点作 12 AM）
 * - 冒号每秒闪烁（1Hz）
 * - 磷光辉光（橙色光晕 + 轻微暗色投影）
 * - 等宽粗体 + 微字距（DV 位图字体的方正感）
 * - layer.zPosition = 8，永远浮在 Ken Burns 缩放的照片（z=4）之上
 */
final class DateStampView: UILabel {

    static let classicOrange = 0xFFFF7F27

    /// 有冒号 / 无冒号两份文本
    private let withColon: NSAttributedString
    private let withoutColon: NSAttributedString
    private var blinkTimer: Timer?
    private var showColon = true

    /**
     * @param timeMs     照片的 NAS 原始拍摄时间（毫秒）
     * @param textSizePt 字号：全屏 17pt，半屏格 13pt，电影遮幅 15pt
     */
    init(timeMs: Int64, textSizePt: CGFloat = 17) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000.0)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let y = comps.year ?? 2000
        let mo = comps.month ?? 1
        let d = comps.day ?? 1
        let h24 = comps.hour ?? 0
        let minute = comps.minute ?? 0

        let amPm = h24 >= 12 ? "PM" : "AM"
        let h12 = { (v: Int) -> Int in let r = v % 12; return r == 0 ? 12 : r }(h24)
        let dateLine = String(format: "%04d.%02d.%02d", y, mo, d)
        withColon = DateStampView.attributed(
            text: "\(dateLine)\n\(amPm) \(h12):\(minute)", size: textSizePt
        )
        withoutColon = DateStampView.attributed(
            text: "\(dateLine)\n\(amPm) \(h12) \(minute)", size: textSizePt
        )

        super.init(frame: .zero)
        numberOfLines = 0
        attributedText = withColon
        alpha = 0.96
        // 日期戳必须高于照片视图（分屏格 z=4），否则会被 Ken Burns 动画照片遮住
        layer.zPosition = 8
        // 磷光辉光：橙色柔光 + 轻微暗色投影（白天可读）
        layer.shadowColor = UIColor(argb: 0x99FF7F27).cgColor
        layer.shadowRadius = 10
        layer.shadowOpacity = 0.8
        layer.shadowOffset = .zero
        layer.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// 等宽粗体 + 微字距 + 2pt 行距的 DV 风格排版
    private static func attributed(text: String, size: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.alignment = .right
        return NSAttributedString(string: text, attributes: [
            .font: UIFont(name: "Menlo-Bold", size: size) ?? UIFont.boldSystemFont(ofSize: size),
            .foregroundColor: UIColor(argb: classicOrange),
            .kern: 0.6,
            .paragraphStyle: paragraph
        ])
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow != nil {
            startBlink()
        } else {
            stopBlink() // 舞台销毁时自动停止冒号闪烁
        }
    }

    private func startBlink() {
        stopBlink()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.showColon = !self.showColon
            self.attributedText = self.showColon ? self.withColon : self.withoutColon
        }
    }

    private func stopBlink() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    deinit {
        stopBlink()
    }
}
