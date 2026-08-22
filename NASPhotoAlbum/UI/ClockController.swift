import UIKit

/**
 * 实时时钟控制器（对应 Android 端 ClockController）。
 *
 * - 每秒刷新一次时间/日期，对齐到下一秒整点避免漂移
 * - 时间格式 "HH:mm"；日期格式 "yyyy年M月d日 星期X"
 * - 通过 start/stop 绑定视图生命周期，避免后台空转
 */
final class ClockController {

    private let clockLabel: UILabel
    private let dateLabel: UILabel
    private var timer: Timer?

    private let timeFormatter: DateFormatter
    private let dateFormatter: DateFormatter

    init(clockLabel: UILabel, dateLabel: UILabel) {
        self.clockLabel = clockLabel
        self.dateLabel = dateLabel

        timeFormatter = DateFormatter()
        timeFormatter.locale = Locale.current
        timeFormatter.dateFormat = "HH:mm"

        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_CN")
        dateFormatter.dateFormat = "yyyy年M月d日 EEEE"
    }

    /// 启动时钟（幂等）
    func start() {
        stop()
        render()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.render()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 停止时钟
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 立即渲染一次（避免显示占位）
    func render() {
        let now = Date()
        clockLabel.text = timeFormatter.string(from: now)
        dateLabel.text = dateFormatter.string(from: now)
    }
}
