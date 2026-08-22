import UIKit

/**
 * 时钟外观设置弹窗（对应 Android 端 ClockAppearanceDialogFragment）。
 *
 * - 顶部大预览区：实时时钟 + 日期，支持直接拖拽调整位置（比例存储 0~1）
 * - 字体 / 字号 / 颜色 / 阴影 / 描边开关 + 描边颜色，全部即时生效
 * - "重置位置"回到默认，"完成"关闭弹窗
 */
final class ClockAppearanceViewController: UIViewController {

    private let settings = AppServices.shared.settings

    // MARK: - 视图

    private let previewArea = UIView()
    private var previewClock = StrokeLabel()
    private var previewDate = UILabel()
    private var previewOverlay = ClockOverlayView()

    private let fontSeg = UISegmentedControl()
    private let sizeSlider = UISlider()
    private let sizeValueLabel = UILabel()
    private let shadowSeg = UISegmentedControl()
    private let strokeSwitch = UISwitch()
    private let resetButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)

    private var clockController: ClockController!

    // MARK: - 生命周期

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit { clockController?.stop() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(argb: 0xFF0E1015)
        buildUI()
        applyAppearance()
        clockController = ClockController(clockLabel: previewClock, dateLabel: previewDate)
        clockController.start()
    }

    // MARK: - UI 构建

    private func buildUI() {
        // 预览区（深色磨砂背景，模拟幻灯片画面）
        previewArea.backgroundColor = UIColor(argb: 0xFF232830)
        previewArea.layer.cornerRadius = 18
        view.addSubview(previewArea)

        previewOverlay.backgroundColor = .clear
        previewOverlay.isUserInteractionEnabled = true
        previewArea.addSubview(previewOverlay)

        previewClock.font = .boldSystemFont(ofSize: 48)
        previewClock.textColor = .white
        previewClock.textAlignment = .center
        previewOverlay.addSubview(previewClock)

        previewDate.font = .systemFont(ofSize: 15)
        previewDate.textColor = .white
        previewDate.textAlignment = .center
        previewOverlay.addSubview(previewDate)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        previewOverlay.addGestureRecognizer(pan)

        // 字体
        let fontLabel = sectionLabel("字体")
        view.addSubview(fontLabel)
        for (i, f) in ClockFont.allCases.enumerated() {
            fontSeg.insertSegment(withTitle: f.display, at: i, animated: false)
        }
        fontSeg.selectedSegmentIndex = settings.getClockFont().rawValue
        styleSeg(fontSeg)
        fontSeg.addTarget(self, action: #selector(fontChanged), for: .valueChanged)
        view.addSubview(fontSeg)

        // 字号
        let sizeLabel = sectionLabel("字号")
        view.addSubview(sizeLabel)
        sizeSlider.minimumValue = 24
        sizeSlider.maximumValue = 120
        sizeSlider.value = Float(settings.getClockSizeSp())
        sizeSlider.minimumTrackTintColor = UIColor(argb: 0xFFE8B64C)
        sizeSlider.addTarget(self, action: #selector(sizeChanged), for: .valueChanged)
        view.addSubview(sizeSlider)

        sizeValueLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        sizeValueLabel.textColor = UIColor(white: 1.0, alpha: 0.6)
        sizeValueLabel.textAlignment = .right
        view.addSubview(sizeValueLabel)

        // 颜色
        let colorLabel = sectionLabel("颜色")
        view.addSubview(colorLabel)
        for i in 0..<SettingsStore.clockColors.count {
            view.addSubview(colorSwatch(
                color: SettingsStore.clockColor(of: i),
                action: #selector(pickClockColor(_:)),
                tag: 100 + i
            ))
        }

        // 阴影
        let shadowLabel = sectionLabel("阴影")
        view.addSubview(shadowLabel)
        for (i, s) in ClockShadow.allCases.enumerated() {
            shadowSeg.insertSegment(withTitle: s.display, at: i, animated: false)
        }
        shadowSeg.selectedSegmentIndex = settings.getClockShadow().rawValue
        styleSeg(shadowSeg)
        shadowSeg.addTarget(self, action: #selector(shadowChanged), for: .valueChanged)
        view.addSubview(shadowSeg)

        // 描边
        let strokeLabel = sectionLabel("描边")
        view.addSubview(strokeLabel)
        strokeSwitch.onTintColor = UIColor(argb: 0xFFE8B64C)
        strokeSwitch.isOn = settings.clockStrokeEnabled
        strokeSwitch.addTarget(self, action: #selector(strokeChanged), for: .valueChanged)
        view.addSubview(strokeSwitch)

        for i in 0..<SettingsStore.strokeColors.count {
            view.addSubview(colorSwatch(
                color: SettingsStore.strokeColor(of: i),
                action: #selector(pickStrokeColor(_:)),
                tag: 200 + i
            ))
        }

        // 按钮
        resetButton.setTitle("重置位置", for: .normal)
        resetButton.setTitleColor(UIColor(white: 1.0, alpha: 0.7), for: .normal)
        resetButton.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        resetButton.layer.cornerRadius = 18
        resetButton.addTarget(self, action: #selector(resetPosition), for: .touchUpInside)
        view.addSubview(resetButton)

        doneButton.setTitle("完 成", for: .normal)
        doneButton.setTitleColor(UIColor(argb: 0xFF2A2113), for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
        doneButton.backgroundColor = UIColor(argb: 0xFFE8B64C)
        doneButton.layer.cornerRadius = 18
        doneButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        view.addSubview(doneButton)

        markSelectedSwatches()
        view.setNeedsLayout()
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.textColor = UIColor(white: 1.0, alpha: 0.55)
        l.sizeToFit()
        return l
    }

    private func styleSeg(_ seg: UISegmentedControl) {
        seg.setTitleTextAttributes(
            [NSAttributedString.Key.foregroundColor: UIColor.white], for: .normal
        )
        seg.setTitleTextAttributes(
            [NSAttributedString.Key.foregroundColor: UIColor.black], for: .selected
        )
    }

    private func colorSwatch(color: Int, action: Selector, tag: Int) -> UIButton {
        let b = UIButton(type: .custom)
        b.backgroundColor = UIColor(argb: color)
        b.layer.cornerRadius = 14
        b.layer.borderWidth = 2
        b.layer.borderColor = UIColor(white: 1.0, alpha: 0.15).cgColor
        b.tag = tag
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func markSelectedSwatches() {
        // 时钟颜色选中态：读取存储的颜色反查索引
        let clockIdx = (UserDefaults.standard.string(forKey: SettingsStore.keyClockColor) as NSString?)
            .map { $0.integerValue } ?? 0
        let strokeIdx = (UserDefaults.standard.string(forKey: SettingsStore.keyClockStrokeColor) as NSString?)
            .map { $0.integerValue } ?? 0
        for sub in view.subviews where sub is UIButton && sub.tag >= 100 {
            let button = sub as! UIButton
            let base = button.tag < 200 ? 100 : 200
            let idx = button.tag - base
            let selected = button.tag < 200 ? (idx == clockIdx) : (idx == strokeIdx)
            button.layer.borderColor = selected
                ? UIColor(argb: 0xFFE8B64C).cgColor
                : UIColor(white: 1.0, alpha: 0.15).cgColor
            button.layer.borderWidth = selected ? 3 : 2
        }
    }

    // MARK: - 布局

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let top = view.safeAreaInsets.top + 16

        previewArea.frame = CGRect(x: 20, y: top, width: w - 40, height: 190)
        ClockAppearance.positionOverlay(
            overlay: previewOverlay, in: previewArea, store: settings, animated: false
        )

        var y = top + 206
        let pad: CGFloat = 24

        if let l = view.subviews.first(where: { $0 is UILabel && ($0 as! UILabel).text == "字体" }) {
            l.frame.origin = CGPoint(x: pad, y: y + 8)
            fontSeg.frame = CGRect(x: pad + 52, y: y, width: w - pad * 2 - 52, height: 30)
            y += 48
        }
        if let l = view.subviews.first(where: { $0 is UILabel && ($0 as! UILabel).text == "字号" }) {
            l.frame.origin = CGPoint(x: pad, y: y + 8)
            sizeSlider.frame = CGRect(x: pad + 52, y: y, width: w - pad * 2 - 52 - 60, height: 30)
            sizeValueLabel.frame = CGRect(x: w - pad - 56, y: y + 4, width: 56, height: 22)
            y += 48
        }
        if let l = view.subviews.first(where: { $0 is UILabel && ($0 as! UILabel).text == "颜色" }) {
            l.frame.origin = CGPoint(x: pad, y: y + 14)
            var x = pad + 52
            for sub in view.subviews where sub is UIButton && sub.tag >= 100 && sub.tag < 200 {
                sub.frame = CGRect(x: x, y: y, width: 44, height: 44)
                x += 56
            }
            y += 60
        }
        if let l = view.subviews.first(where: { $0 is UILabel && ($0 as! UILabel).text == "阴影" }) {
            l.frame.origin = CGPoint(x: pad, y: y + 8)
            shadowSeg.frame = CGRect(x: pad + 52, y: y, width: w - pad * 2 - 52, height: 30)
            y += 48
        }
        if let l = view.subviews.first(where: { $0 is UILabel && ($0 as! UILabel).text == "描边" }) {
            l.frame.origin = CGPoint(x: pad, y: y + 8)
            strokeSwitch.frame = CGRect(x: pad + 52, y: y, width: 52, height: 31)
            var x = strokeSwitch.frame.maxX + 20
            for sub in view.subviews where sub is UIButton && sub.tag >= 200 {
                sub.frame = CGRect(x: x, y: y - 7, width: 44, height: 44)
                x += 56
            }
            y += 64
        }

        resetButton.frame = CGRect(x: pad, y: y, width: 130, height: 40)
        doneButton.frame = CGRect(x: w - pad - 130, y: y, width: 130, height: 40)
    }

    // MARK: - 交互

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: previewArea)
        let size = previewArea.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let xRatio = Float(min(max(location.x / size.width, 0), 1))
        let yRatio = Float(min(max(location.y / size.height, 0), 1))
        settings.setClockPositionRatio(x: xRatio, y: yRatio)
        ClockAppearance.positionOverlay(
            overlay: previewOverlay, in: previewArea, store: settings, animated: false
        )
        if g.state == .ended {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    @objc private func fontChanged() {
        settings.setClockFont(ClockFont.fromValue(fontSeg.selectedSegmentIndex))
        applyAppearance()
    }

    @objc private func sizeChanged() {
        settings.setClockSizeSp(Int(sizeSlider.value))
        applyAppearance()
    }

    @objc private func pickClockColor(_ sender: UIButton) {
        settings.setClockColorIndex(sender.tag - 100)
        applyAppearance()
        markSelectedSwatches()
    }

    @objc private func shadowChanged() {
        settings.setClockShadow(ClockShadow.fromValue(shadowSeg.selectedSegmentIndex))
        applyAppearance()
    }

    @objc private func strokeChanged() {
        settings.clockStrokeEnabled = strokeSwitch.isOn
        applyAppearance()
    }

    @objc private func pickStrokeColor(_ sender: UIButton) {
        settings.setClockStrokeColorIndex(sender.tag - 200)
        applyAppearance()
        markSelectedSwatches()
    }

    @objc private func resetPosition() {
        settings.setClockPositionRatio(x: 0.90, y: 0.10)
        ClockAppearance.positionOverlay(
            overlay: previewOverlay, in: previewArea, store: settings, animated: true
        )
    }

    @objc private func close() {
        dismiss(animated: true, completion: nil)
    }

    // MARK: - 应用外观

    private func applyAppearance() {
        ClockAppearance.apply(
            store: settings,
            overlay: previewOverlay,
            clock: previewClock,
            date: previewDate
        )
        sizeValueLabel.text = "\(settings.getClockSizeSp()) pt"
    }
}
