import UIKit
import AVFoundation

/**
 * 幻灯片播放界面（对应 Android 端 SlideshowFragment，交互一比一移植）。
 *
 * 交互：
 * - 单击：显示/隐藏控制栏（4 秒无操作自动隐藏）
 * - 双击：播放/暂停
 * - 左滑：下一页；右滑：上一页
 * - 控制栏：退出 / 上一页 / 播放暂停 / 下一页
 *
 * 渲染：
 * - 双舞台交替显示避免闪烁；过渡动画（淡入淡出/滑动/缩放）作用于舞台容器整体
 * - 内容由 StageRenderer 按展示模式渲染
 * - 时钟覆盖层（样式/外观/位置全部跟随设置）
 *
 * 夜间休眠：
 * - 纯黑遮罩淡入盖住全部内容，短显"恢复时刻"提示后完全黑屏
 * - 30 秒心跳 + 精确边界检查，到点自动恢复展示
 */
final class SlideshowViewController: UIViewController {

    // MARK: - 服务

    private let settings = AppServices.shared.settings
    private lazy var engine = SlideshowEngine(
        settings: AppServices.shared.settings,
        photoRepository: AppServices.shared.photoRepository,
        cacheManager: AppServices.shared.cacheManager,
        scanCoordinator: AppServices.shared.scanCoordinator
    )
    private let stageRenderer = StageRenderer()
    private var clockController: ClockController!

    // MARK: - 视图

    private let stageA = UIView()
    private let stageB = UIView()

    private let clockOverlay = ClockOverlayView()
    private var clockLabel = StrokeLabel()
    private var dateLabel = UILabel()

    private var loadingOverlay: UIView!
    private var loadingSpinner: UIActivityIndicatorView!
    private var loadingHintLabel: UILabel!

    private var controlBar: UIView!
    private var btnExit: UIButton!
    private var btnPrev: UIButton!
    private var btnPlayPause: UIButton!
    private var btnNext: UIButton!

    private let blackoutOverlay = UIView()
    private let nightHintLabel = UILabel()

    // MARK: - 状态

    private var frontIsA = true
    private var isAnimating = false
    private var lastShownPath: String?
    private var isNightSleeping = false
    private var nightCheckTimer: Timer?
    private var nightHintFadeWork: DispatchWorkItem?
    private var hideControlBarWork: DispatchWorkItem?

    /// 拍立得卡片日期文字（照片拍摄时间）
    private let captionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f
    }()

    // MARK: - 生命周期

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    deinit {
        engine.pause()                 // 停止推进定时器
        stageRenderer.release()        // 释放播放器/KVO/动画
        nightCheckTimer?.invalidate()
        nightHintFadeWork?.cancel()
        hideControlBarWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildUI()
        setupGestures()
        setupClock()
        engine.onStateChange = { [weak self] state in
            self?.renderState(state)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 沉浸模式：隐藏导航栏（对应 Android immersive）
        navigationController?.setNavigationBarHidden(true, animated: animated)
        // 相框应用：保持屏幕常亮
        UIApplication.shared.isIdleTimerDisabled = true
        // 从设置页返回后重新应用时钟外观（改动即时生效）
        applyClockAppearance()
        checkNightSchedule()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
        UIApplication.shared.isIdleTimerDisabled = false
        clockController.stop()
    }

    // MARK: - UI 构建

    private func buildUI() {
        // 双舞台
        for stage in [stageA, stageB] {
            stage.frame = view.bounds
            stage.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stage.clipsToBounds = true
            view.addSubview(stage)
        }
        stageB.isHidden = true

        // 时钟覆盖层
        clockOverlay.backgroundColor = .clear
        clockOverlay.isUserInteractionEnabled = false
        clockLabel.font = .boldSystemFont(ofSize: 48)
        clockLabel.textColor = .white
        clockLabel.textAlignment = .center
        dateLabel.font = .systemFont(ofSize: 15)
        dateLabel.textColor = .white
        dateLabel.textAlignment = .center
        clockOverlay.addSubview(clockLabel)
        clockOverlay.addSubview(dateLabel)
        view.addSubview(clockOverlay)

        // 控制栏
        controlBar = buildControlBar()
        controlBar.alpha = 0
        controlBar.isHidden = true
        view.addSubview(controlBar)

        // 加载遮罩
        loadingOverlay = UIView(frame: view.bounds)
        loadingOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        loadingOverlay.backgroundColor = UIColor(white: 0.04, alpha: 1.0)
        loadingSpinner = UIActivityIndicatorView(style: .whiteLarge)
        loadingSpinner.startAnimating()
        loadingHintLabel = UILabel()
        loadingHintLabel.textColor = UIColor(white: 1.0, alpha: 0.7)
        loadingHintLabel.font = .systemFont(ofSize: 15)
        loadingHintLabel.textAlignment = .center
        loadingHintLabel.numberOfLines = 0
        loadingOverlay.addSubview(loadingSpinner)
        loadingOverlay.addSubview(loadingHintLabel)
        view.addSubview(loadingOverlay)

        // 夜间休眠遮罩（纯黑 + 提示文字）
        blackoutOverlay.frame = view.bounds
        blackoutOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blackoutOverlay.backgroundColor = .black
        blackoutOverlay.isUserInteractionEnabled = true // 拦截手势
        blackoutOverlay.alpha = 0
        blackoutOverlay.isHidden = true
        view.addSubview(blackoutOverlay)

        nightHintLabel.textColor = UIColor(white: 1.0, alpha: 0.55)
        nightHintLabel.font = .systemFont(ofSize: 16)
        nightHintLabel.textAlignment = .center
        nightHintLabel.numberOfLines = 0
        nightHintLabel.alpha = 0
        nightHintLabel.isHidden = true
        blackoutOverlay.addSubview(nightHintLabel)

        view.setNeedsLayout()
    }

    private func buildControlBar() -> UIView {
        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.0, alpha: 0.55)
        bar.layer.cornerRadius = 26

        btnExit = SlideshowViewController.ctrlButton(symbol: "✕", hint: "退出")
        btnPrev = SlideshowViewController.ctrlButton(symbol: "‹", hint: "上一页")
        btnPlayPause = SlideshowViewController.ctrlButton(symbol: "❚❚", hint: "暂停")
        btnNext = SlideshowViewController.ctrlButton(symbol: "›", hint: "下一页")

        btnExit.addTarget(self, action: #selector(exitTapped), for: .touchUpInside)
        btnPrev.addTarget(self, action: #selector(prevTapped), for: .touchUpInside)
        btnPlayPause.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        btnNext.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)

        for b in [btnExit!, btnPrev!, btnPlayPause!, btnNext!] { bar.addSubview(b) }
        return bar
    }

    private class func ctrlButton(symbol: String, hint: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(symbol, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 26, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.accessibilityLabel = hint
        return button
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        loadingSpinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY - 24)
        loadingHintLabel.frame = CGRect(
            x: 40, y: view.bounds.midY + 24,
            width: view.bounds.width - 80, height: 44
        )
        nightHintLabel.frame = CGRect(
            x: 32, y: view.bounds.midY - 22,
            width: view.bounds.width - 64, height: 44
        )

        let barSize = CGSize(width: 252, height: 56)
        controlBar.frame = CGRect(
            x: (view.bounds.width - barSize.width) / 2,
            y: view.bounds.height - barSize.height - 28,
            width: barSize.width, height: barSize.height
        )
        let slot = barSize.width / 4
        let buttons = [btnExit!, btnPrev!, btnPlayPause!, btnNext!]
        for (i, b) in buttons.enumerated() {
            b.frame = CGRect(x: slot * CGFloat(i), y: 0, width: slot, height: barSize.height)
        }
    }

    // MARK: - 时钟

    private func setupClock() {
        clockController = ClockController(clockLabel: clockLabel, dateLabel: dateLabel)
        clockController.start()
    }

    private func applyClockAppearance() {
        ClockAppearance.apply(
            store: settings,
            overlay: clockOverlay,
            clock: clockLabel,
            date: dateLabel
        )
    }

    // MARK: - 手势（对应 Android GestureDetector）

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        // 单击等待双击失败后才触发（等价 onSingleTapConfirmed）
        singleTap.require(toFail: doubleTap)

        let swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeLeft.direction = .left
        let swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        swipeRight.direction = .right

        for g in [singleTap, doubleTap, swipeLeft, swipeRight] {
            view.addGestureRecognizer(g)
        }
    }

    @objc private func handleSingleTap() {
        toggleControlBar()
    }

    @objc private func handleDoubleTap() {
        engine.toggle()
    }

    @objc private func handleSwipe(_ g: UISwipeGestureRecognizer) {
        if isNightSleeping { return }
        if g.direction == .left { engine.next() } else { engine.prev() }
    }

    // MARK: - 控制栏

    private func toggleControlBar() {
        if controlBar.isHidden || controlBar.alpha < 0.5 {
            showControlBar()
        } else {
            hideControlBar()
        }
    }

    private func showControlBar() {
        hideControlBarWork?.cancel()
        controlBar.isHidden = false
        controlBar.alpha = 0
        UIView.animate(withDuration: 0.25) {
            self.controlBar.alpha = 1
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideControlBar()
        }
        hideControlBarWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: work)
    }

    private func hideControlBar() {
        hideControlBarWork?.cancel()
        guard !controlBar.isHidden else { return }
        UIView.animate(
            withDuration: 0.25,
            animations: { self.controlBar.alpha = 0 },
            completion: { _ in
                if self.controlBar.alpha < 0.05 { self.controlBar.isHidden = true }
            }
        )
    }

    @objc private func exitTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func prevTapped() {
        engine.prev()
        showControlBar()
    }

    @objc private func nextTapped() {
        engine.next()
        showControlBar()
    }

    @objc private func playPauseTapped() {
        engine.toggle()
        showControlBar()
    }

    // MARK: - 状态订阅（对应 renderState）

    private func renderState(_ state: PlaybackState) {
        switch state {
        case .loading:
            loadingOverlay.isHidden = false
            loadingHintLabel.text = "正在准备照片…"

        case .empty(let reason):
            loadingOverlay.isHidden = false
            loadingHintLabel.text = reason

        case .playing(let current, let localFile, _, _, let upcoming, let videoFile):
            loadingOverlay.isHidden = true
            showIfNeeded(path: current.fullPath, file: localFile,
                         videoFile: videoFile, upcoming: upcoming, photoTimeMs: current.lastModified)
            btnPlayPause.setTitle("❚❚", for: .normal)

        case .paused(let current, let localFile, _, _, let upcoming, let videoFile):
            loadingOverlay.isHidden = true
            showIfNeeded(path: current.fullPath, file: localFile,
                         videoFile: videoFile, upcoming: upcoming, photoTimeMs: current.lastModified)
            btnPlayPause.setTitle("▶", for: .normal)
        }
    }

    private func showIfNeeded(
        path: String,
        file: URL,
        videoFile: URL?,
        upcoming: [UpcomingPhoto],
        photoTimeMs: Int64
    ) {
        guard lastShownPath != path, !isAnimating else { return }
        showPhoto(
            file: file,
            videoFile: videoFile,
            upcoming: upcoming,
            photoTimeMs: photoTimeMs
        )
        lastShownPath = path
    }

    // MARK: - 照片渲染与过渡动画（对应 showPhoto/applyTransition）

    private func showPhoto(
        file: URL,
        videoFile: URL?,
        upcoming: [UpcomingPhoto],
        photoTimeMs: Int64
    ) {
        let caption = captionFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(photoTimeMs) / 1000.0))

        let frontStage = frontIsA ? stageA : stageB
        let backStage = frontIsA ? stageB : stageA

        // 重置前层舞台的变换属性（避免上轮过渡动画残留导致黑屏）
        frontStage.alpha = 1
        frontStage.transform = .identity

        _ = stageRenderer.render(
            stage: frontStage,
            mode: settings.getEffectiveDisplayMode(),
            current: file,
            upcoming: upcoming,
            caption: caption,
            intervalMs: settings.getPlayIntervalMs(),
            photoTimeMs: photoTimeMs,
            videoFile: videoFile
        )
        // 回报本页展示的不重复照片数，作为下一次推进的步长
        engine.onPageConsumed(stageRenderer.lastConsumedCount)

        applyTransition(front: frontStage, back: backStage)
    }

    /// 根据设置应用过渡动画（作用于舞台容器整体，日期戳/时钟随舞台一起过渡）
    private func applyTransition(front: UIView, back: UIView) {
        // MEMORIES 模式强制淡入淡出（iOS 回忆风格）
        let type = settings.getDisplayMode() == .memories
            ? TransitionType.fade
            : settings.getTransitionType()
        let duration: TimeInterval = 0.3

        switch type {
        case .none:
            front.isHidden = false
            back.isHidden = true
            frontIsA.toggle()

        case .fade:
            front.isHidden = false
            front.alpha = 0
            playTransition(duration: duration, animations: {
                front.alpha = 1
                back.alpha = 0
            }, front: front, back: back, onEnd: nil)

        case .slide:
            let width = max(view.bounds.width, 1)
            front.isHidden = false
            front.transform = CGAffineTransform(translationX: width, y: 0)
            playTransition(duration: duration, animations: {
                front.transform = .identity
                back.transform = CGAffineTransform(translationX: -width, y: 0)
            }, front: front, back: back, onEnd: {
                back.transform = .identity
            })

        case .zoom:
            front.isHidden = false
            front.alpha = 0
            front.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
            playTransition(duration: duration, animations: {
                front.transform = .identity
                front.alpha = 1
                back.alpha = 0
            }, front: front, back: back, onEnd: {
                back.alpha = 1
            })
        }
    }

    /// 执行动画并在结束时交换前后层
    private func playTransition(
        duration: TimeInterval,
        animations: @escaping () -> Void,
        front: UIView,
        back: UIView,
        onEnd: (() -> Void)?
    ) {
        isAnimating = true
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState],
            animations: animations,
            completion: { _ in
                back.isHidden = true
                onEnd?()
                self.frontIsA.toggle()
                self.isAnimating = false
            }
        )
    }

    // MARK: - 夜间休眠（对应 enterNightMode/exitNightMode/checkNightSchedule）

    /** 检查当前时刻是否应休眠，并按需切换状态 */
    private func checkNightSchedule() {
        if !settings.nightModeEnabled {
            if isNightSleeping { exitNightMode() }
            scheduleNextNightCheck()
            return
        }
        let inShow = NightSchedule.isShowTimeNow(settings)
        if !inShow, !isNightSleeping {
            enterNightMode()
        } else if inShow, isNightSleeping {
            exitNightMode()
        }
        scheduleNextNightCheck()
    }

    /**
     * 心跳调度：30 秒兜底 + 精确边界（提前到状态切换的瞬间）。
     */
    private func scheduleNextNightCheck() {
        nightCheckTimer?.invalidate()
        let ms = NightSchedule.msUntilNextStateChange(settings)
        let seconds = min(30.0, max(1.0, TimeInterval(ms) / 1000.0))
        nightCheckTimer = Timer.scheduledTimer(
            withTimeInterval: seconds, repeats: false
        ) { [weak self] _ in
            self?.checkNightSchedule()
        }
    }

    /** 进入夜间休眠：黑屏静默（暂停播放、释放动画与播放器、纯黑遮罩淡入） */
    private func enterNightMode() {
        isNightSleeping = true
        engine.pause()
        stageRenderer.release()
        hideControlBar()
        clockController.stop()
        clockOverlay.isHidden = true

        nightHintLabel.text = "夜间休眠 · 将于 \(NightSchedule.nextShowStartText(settings)) 恢复展示"
        nightHintLabel.isHidden = false
        nightHintLabel.alpha = 1
        nightHintFadeWork?.cancel()
        let fadeWork = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            UIView.animate(withDuration: 2.0) {
                self.nightHintLabel.alpha = 0
            }
        }
        nightHintFadeWork = fadeWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: fadeWork)

        blackoutOverlay.isHidden = false
        blackoutOverlay.alpha = 0
        UIView.animate(withDuration: 0.8) {
            self.blackoutOverlay.alpha = 1
        }
    }

    /** 退出夜间休眠：遮罩淡出，恢复时钟与播放（重渲染当前照片以重启动画） */
    private func exitNightMode() {
        isNightSleeping = false
        nightHintLabel.isHidden = true
        nightHintFadeWork?.cancel()
        blackoutOverlay.alpha = blackoutOverlay.isHidden ? 0 : blackoutOverlay.alpha
        UIView.animate(
            withDuration: 0.8,
            animations: { self.blackoutOverlay.alpha = 0 },
            completion: { _ in
                if !self.isNightSleeping { self.blackoutOverlay.isHidden = true }
            }
        )
        clockOverlay.isHidden = false
        applyClockAppearance()
        clockController.start()
        lastShownPath = nil // 强制重渲染当前照片，重启 Ken Burns / 实况视频
        engine.play()
    }
}
