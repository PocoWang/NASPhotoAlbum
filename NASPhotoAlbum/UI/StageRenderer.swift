import UIKit
import AVFoundation

// MARK: - 人脸居中裁剪视图

/**
 * 人脸居中裁剪图片视图（对应 Android 端 loadFaceCentered + Matrix 方案）。
 *
 * 实现：layer.contentsRect 指定可见区域（单位坐标，原点为图片左上）。
 * 1. 图片就绪后先应用 CenterCrop 等效 contentsRect（先有画面）
 * 2. 后台人脸检测完成后，用 800ms CABasicAnimation 平滑过渡到人脸居中构图
 * 3. 未检测到人脸保持 CenterCrop（负缓存，下次不再检测）
 * 平移量做了越界保护（clamp 在可见区间内），人脸太靠边也不会露出黑边。
 */
final class FaceCropImageView: UIImageView {

    private var faceCenter: FaceCenterDetector.FacePoint?
    private var cropApplied = false
    private var cornerRadiusPt: CGFloat = 0

    convenience init(cornerRadius: CGFloat) {
        self.init(frame: .zero)
        contentMode = .scaleAspectFill
        clipsToBounds = true
        layer.cornerRadius = cornerRadius
        cornerRadiusPt = cornerRadius
    }

    /** 加载图片并异步人脸居中 */
    func loadFaceCentered(file: URL) {
        ImageLoader.shared.load(file: file) { [weak self] image in
            guard let self = self, let image = image, self.window != nil else { return }
            self.image = image
            self.cropApplied = false
            self.setNeedsLayout()
            FaceCenterDetector.shared.faceCenterAsync(file: file) { [weak self] face in
                guard let self = self, let face = face, self.window != nil else { return }
                self.faceCenter = face
                self.applyCrop(animated: true)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if image != nil, !cropApplied {
            applyCrop(animated: false)
        }
    }

    /// 计算并应用 contentsRect
    private func applyCrop(animated: Bool) {
        guard let image = image, bounds.width > 0, bounds.height > 0 else { return }
        let iw = image.size.width
        let ih = image.size.height
        guard iw > 0, ih > 0 else { return }

        let vw = bounds.width
        let vh = bounds.height
        let scale = max(vw / iw, vh / ih) // CenterCrop 等效缩放
        let visW = min(1, vw / (iw * scale))
        let visH = min(1, vh / (ih * scale))

        let x: CGFloat
        let y: CGFloat
        if let face = faceCenter {
            // 人脸中心对齐视图中心，clamp 保证不露黑边
            x = min(max(CGFloat(face.x) - visW / 2, 0), 1 - visW)
            y = min(max(CGFloat(face.y) - visH / 2, 0), 1 - visH)
        } else {
            x = (1 - visW) / 2
            y = (1 - visH) / 2
        }
        let target = CGRect(x: x, y: y, width: visW, height: visH)
        cropApplied = true

        if animated {
            let anim = CABasicAnimation(keyPath: "contentsRect")
            anim.fromValue = layer.contentsRect
            anim.toValue = target
            anim.duration = 0.8
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "faceCrop")
        }
        layer.contentsRect = target
    }
}

// MARK: - 实况视频视图

/// AVPlayerLayer 宿主视图（等效 ExoPlayer PlayerView + zoom 缩放）
final class LivePlayerView: UIView {
    let player: AVPlayer
    private var statusObserver: NSKeyValueObservation?
    var onReady: (() -> Void)?
    var onError: (() -> Void)?

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        videoPlayerLayer.player = player
        var flipped = false
        statusObserver = player.currentItem?.observe(
            \.status,
            options: [.new]
        ) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if item.status == .readyToPlay {
                    self.onReady?()
                } else if item.status == .failed {
                    self.onError?()
                }
            }
        }
        _ = flipped
    }

    private var videoPlayerLayer: AVPlayerLayer { return layer as! AVPlayerLayer }

    override class var layerClass: AnyClass { return AVPlayerLayer.self }

    required init?(coder: NSCoder) { fatalError("unsupported") }
}

// MARK: - 舞台渲染器

/**
 * 幻灯片舞台渲染器（对应 Android 端 StageRenderer 精修版 v3）。
 *
 * 每种展示模式都有独特的视觉语言：
 * - single：全屏沉浸 + 微呼吸 + 柔和暗角 + DV 日期戳
 * - kenBurns：有机推拉 + 缓入缓出 + 随机 pivot + 微旋转
 * - polaroid：拍立得卡片 + 随机倾斜 + 柔和投影 + 掉落弹跳入场
 * - collage：拼贴布局 + 逐图交错入场 + 底部渐变（人脸居中）
 * - splitScreen：分屏对比 + 双侧独立 Ken Burns + 渐变发光中缝（各格 DV 时间戳）
 * - filmstrip：胶片连放 + 复古齿孔 + 帧号标记
 * - mosaic：马赛克网格 + 波浪式交错浮现
 * - cinematic：2.35:1 画幅 + Ken Burns + 胶片颗粒质感
 * - memories：iOS 回忆风格（Ken Burns + 多种布局变化，无标题无日期叠加）
 */
final class StageRenderer {

    /// 实况照片动态视频播放器（切页/销毁时释放）
    private var livePlayer: AVPlayer?
    private var livePlayerView: LivePlayerView?

    /// 允许播放实况视频的模式（单张全屏类；多图/卡片类保持静态图）
    private let livePlayableModes: Set<DisplayMode> = [.single, .kenBurns, .random]

    /// 活动中的属性动画器（切页/休眠时取消）
    private var animators: [UIViewPropertyAnimator] = []

    /// 最近一次 render 实际展示的不重复照片数（含当前张），UI 回报给引擎作推进步长
    private(set) var lastConsumedCount = 1

    private var isPortraitStage = false

    // MARK: - 渲染入口

    /**
     * 向 stage 渲染一组照片。
     * @return 是否有持续动画在播放（Ken Burns 类），调用方在切换时取消
     */
    @discardableResult
    func render(
        stage: UIView,
        mode: DisplayMode,
        current: URL,
        upcoming: [UpcomingPhoto],
        caption: String?,
        intervalMs: Int64,
        photoTimeMs: Int64,
        videoFile: URL?
    ) -> Bool {
        release()
        stage.subviews.forEach { $0.removeFromSuperview() }
        stage.backgroundColor = .clear

        isPortraitStage = stage.bounds.height >= stage.bounds.width

        // 净化后续列表：剔除当前张与重复项，保证同页内每张照片都不同
        let uniqueUpcoming = upcoming
            .filter { $0.file.path != current.path }
            .reduce(into: [UpcomingPhoto]()) { acc, p in
                if !acc.contains(where: { $0.file.path == p.file.path }) { acc.append(p) }
            }
        let upcomingFiles = uniqueUpcoming.map { $0.file }

        // 记录本页将展示的不重复照片数（MEMORIES 拼贴变体会在内部修正为 3）
        switch mode {
        case .collage: lastConsumedCount = 1 + min(2, upcomingFiles.count)
        case .splitScreen: lastConsumedCount = 1 + min(1, upcomingFiles.count)
        case .filmstrip:
            lastConsumedCount = min(isPortraitStage ? 2 : 3, 1 + upcomingFiles.count)
        case .mosaic:
            lastConsumedCount = min(isPortraitStage ? 6 : 9, 1 + upcomingFiles.count)
        default: lastConsumedCount = 1
        }

        // 实况照片视频：仅单张类模式播放
        let liveVideo = (videoFile != nil && livePlayableModes.contains(mode)) ? videoFile : nil

        let hasAnimation: Bool
        switch mode {
        case .single:
            hasAnimation = liveVideo != nil
                ? buildLivePhoto(stage: stage, current: current, videoFile: liveVideo!, photoTimeMs: photoTimeMs)
                : buildSingle(stage: stage, current: current, intervalMs: intervalMs, photoTimeMs: photoTimeMs)
        case .kenBurns:
            hasAnimation = liveVideo != nil
                ? buildLivePhoto(stage: stage, current: current, videoFile: liveVideo!, photoTimeMs: photoTimeMs)
                : buildKenBurns(stage: stage, current: current, intervalMs: intervalMs, photoTimeMs: photoTimeMs)
        case .polaroid:
            buildPolaroid(stage: stage, current: current, caption: caption)
            hasAnimation = false
        case .collage:
            buildCollage(stage: stage, current: current, upcoming: upcomingFiles)
            hasAnimation = false
        case .splitScreen:
            buildSplitScreen(stage: stage, current: current, upcoming: uniqueUpcoming,
                             intervalMs: intervalMs, photoTimeMs: photoTimeMs)
            hasAnimation = false
        case .filmstrip:
            buildFilmstrip(stage: stage, current: current, upcoming: upcomingFiles)
            hasAnimation = false
        case .mosaic:
            buildMosaic(stage: stage, current: current, upcoming: upcomingFiles)
            hasAnimation = false
        case .cinematic:
            hasAnimation = buildCinematic(stage: stage, current: current,
                                          intervalMs: intervalMs, photoTimeMs: photoTimeMs)
        case .memories:
            hasAnimation = buildMemories(stage: stage, current: current, upcoming: upcomingFiles,
                                         intervalMs: intervalMs, photoTimeMs: photoTimeMs)
        case .random:
            // RANDOM 已在上游解析为具体模式，兜底单张
            hasAnimation = liveVideo != nil
                ? buildLivePhoto(stage: stage, current: current, videoFile: liveVideo!, photoTimeMs: photoTimeMs)
                : buildSingle(stage: stage, current: current, intervalMs: intervalMs, photoTimeMs: photoTimeMs)
        }

        // 立即布局，保证后续动画拿到正确 bounds
        stage.setNeedsLayout()
        stage.layoutIfNeeded()

        // 启动挂起的入场/Ken Burns 动画
        for pending in pendingAnimations {
            pending()
        }
        pendingAnimations.removeAll()

        return hasAnimation
    }

    /// 入场/动画闭包队列（布局完成后统一启动）
    private var pendingAnimations: [() -> Void] = []

    /// 取消全部动画并释放播放器（切页/休眠/销毁时调用）
    func release() {
        animators.forEach { $0.stopAnimation(true) }
        animators.removeAll()
        pendingAnimations.removeAll()
        releaseLivePlayer()
    }

    private func releaseLivePlayer() {
        livePlayerView?.removeFromSuperview()
        livePlayerView = nil
        livePlayer?.pause()
        livePlayer?.replaceCurrentItem(with: nil)
        livePlayer = nil
    }

    // MARK: - 工具

    private func makeImageView(stage: UIView) -> UIImageView {
        let iv = UIImageView(frame: stage.bounds)
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(iv)
        return iv
    }

    private func loadInto(_ iv: UIImageView, file: URL) {
        ImageLoader.shared.load(file: file) { [weak iv] image in
            guard let iv = iv, iv.window != nil else { return }
            iv.image = image
        }
    }

    private func fadeIn(_ view: UIView, duration: TimeInterval) {
        view.alpha = 0
        pendingAnimations.append {
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut]) {
                view.alpha = 1
            }
        }
    }

    /** 暗角渐变（4 向） */
    private func addVignetteCorners(stage: UIView, intensity: CGFloat) {
        let alpha = intensity
        let black = UIColor.black.withAlphaComponent(alpha)
        let clear = UIColor.black.withAlphaComponent(0)
        let size: CGFloat = 100
        let b = stage.bounds

        let top = GradientView(colors: [black, clear], startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        top.frame = CGRect(x: 0, y: 0, width: b.width, height: size)
        top.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        stage.addSubview(top)

        let bottom = GradientView(colors: [clear, black], startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        bottom.frame = CGRect(x: 0, y: b.height - size, width: b.width, height: size)
        bottom.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(bottom)

        let left = GradientView(colors: [black, clear], startPoint: .init(x: 0, y: 0.5), endPoint: .init(x: 1, y: 0.5))
        left.frame = CGRect(x: 0, y: 0, width: size, height: b.height)
        left.autoresizingMask = [.flexibleHeight, .flexibleRightMargin]
        stage.addSubview(left)

        let right = GradientView(colors: [clear, black], startPoint: .init(x: 0, y: 0.5), endPoint: .init(x: 1, y: 0.5))
        right.frame = CGRect(x: b.width - size, y: 0, width: size, height: b.height)
        right.autoresizingMask = [.flexibleHeight, .flexibleLeftMargin]
        stage.addSubview(right)
    }

    /** 底部渐变暗角 */
    private func addBottomScrim(stage: UIView, heightPt: CGFloat, intensity: CGFloat) {
        let black = UIColor.black.withAlphaComponent(intensity)
        let clear = UIColor.black.withAlphaComponent(0)
        let scrim = GradientView(colors: [clear, black], startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        scrim.frame = CGRect(x: 0, y: stage.bounds.height - heightPt, width: stage.bounds.width, height: heightPt)
        scrim.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(scrim)
    }

    /** 添加 DV 日期戳（右下角内缩 marginPt） */
    private func addDateStamp(container: UIView, timeMs: Int64, sizePt: CGFloat = 17, marginPt: CGFloat = 26) {
        let stamp = DateStampView(timeMs: timeMs, textSizePt: sizePt)
        stamp.sizeToFit()
        let w = stamp.bounds.width
        let h = stamp.bounds.height
        let x = container.bounds.width - w - marginPt
        let y = container.bounds.height - h - marginPt
        stamp.frame = CGRect(x: x, y: y, width: w, height: h)
        stamp.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
        container.addSubview(stamp)
    }

    /** 多图交错入场：首图缩放浮现，后续依次延迟 100ms 上浮淡入 */
    private func animateChildrenStaggered(_ views: [UIView], baseDelay: TimeInterval = 0, step: TimeInterval = 0.1) {
        views.enumerated().forEach { idx, v in
            if idx == 0 {
                v.alpha = 0
                v.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
                pendingAnimations.append {
                    UIView.animate(withDuration: 0.35, delay: baseDelay, options: [.curveEaseOut]) {
                        v.alpha = 1
                        v.transform = .identity
                    }
                }
            } else {
                v.alpha = 0
                v.transform = CGAffineTransform(translationX: 0, y: 20).scaledBy(x: 0.88, y: 0.88)
                pendingAnimations.append {
                    UIView.animate(withDuration: 0.35, delay: baseDelay + step * TimeInterval(idx),
                                   options: [.curveEaseOut]) {
                        v.alpha = 1
                        v.transform = .identity
                    }
                }
            }
        }
    }

    /**
     * Ken Burns 慢速推拉（精修版 v3：微旋转 + 有机轨迹 + 人脸 pivot + 缓入缓出）。
     * 用变换实现：Translate(px·(1-s)+dx, py·(1-s)+dy) ∘ Scale(s) ∘ Rotate(θ)，
     * 其中 (px,py) 为 pivot 点（人脸中心缓存命中时用，否则随机）。
     */
    private func buildKenBurnsAnimator(
        _ iv: UIImageView,
        intervalMs: Int64,
        zoomTo: CGFloat,
        enableRotation: Bool,
        faceFile: URL?
    ) {
        let duration = max(TimeInterval(intervalMs) * 1.2 / 1000.0, 2.4)

        let zoomRange = zoomTo - 1
        let panScale = zoomRange * 130
        let angle = CGFloat.random(in: 0..<(CGFloat.pi * 2))
        let dist = (0.3 + CGFloat.random(in: 0...1) * 0.7) * panScale
        let dx = cos(angle) * dist
        let dy = sin(angle) * dist * 0.7
        let rotation = enableRotation ? (CGFloat.random(in: 0...1) - 0.5) * 2.4 * .pi / 180 : 0

        // pivot：缓存命中用人脸中心，否则随机
        let w = iv.bounds.width
        let h = iv.bounds.height
        let pivot: CGPoint
        if let faceFile = faceFile,
           let face = FaceCenterDetector.shared.faceCenterIfDetected(file: faceFile) {
            pivot = CGPoint(x: w * CGFloat(face.x), y: h * CGFloat(face.y))
        } else {
            pivot = CGPoint(x: w * (0.2 + CGFloat.random(in: 0...0.6)),
                            y: h * (0.2 + CGFloat.random(in: 0...0.6)))
        }

        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) {
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: pivot.x * (1 - zoomTo) + dx, y: pivot.y * (1 - zoomTo) + dy)
            t = t.scaledBy(x: zoomTo, y: zoomTo)
            t = t.rotated(by: rotation)
            iv.transform = t
        }
        animators.append(animator)
        pendingAnimations.append { [weak animator] in
            animator?.startAnimation()
        }
    }

    // MARK: - 实况照片（Live Photo）

    /**
     * 实况照片播放（iOS 回忆效果）。
     * 静态封面 → AVPlayerLayer（就绪后 400ms 淡入）→ 暗角/底部渐变/DV 日期戳。
     * 静音、单次播放，播完停在最后一帧；损坏时移除播放视图回退封面。
     */
    private func buildLivePhoto(stage: UIView, current: URL, videoFile: URL, photoTimeMs: Int64) -> Bool {
        // 1. 静态封面
        let cover = makeImageView(stage: stage)
        loadInto(cover, file: current)

        // 2. 视频播放器
        let item = AVPlayerItem(url: videoFile)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .pause
        let playerView = LivePlayerView(player: player)
        playerView.frame = stage.bounds
        playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        playerView.alpha = 0
        stage.addSubview(playerView)

        playerView.onReady = { [weak playerView] in
            guard let playerView = playerView else { return }
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut]) {
                playerView.alpha = 1
            }
        }
        playerView.onError = { [weak self, weak playerView, weak stage] in
            guard let self = self else { return }
            playerView?.removeFromSuperview()
            self.releaseLivePlayer()
            _ = stage
        }

        livePlayer = player
        livePlayerView = playerView
        player.play()

        // 3. 与单张模式一致的装饰
        addVignetteCorners(stage: stage, intensity: 0.18)
        addBottomScrim(stage: stage, heightPt: 80, intensity: 0.25)
        addDateStamp(container: stage, timeMs: photoTimeMs)

        // 封面淡入（视频就绪前先有画面）
        fadeIn(cover, duration: 0.4)
        return false
    }

    // MARK: - 单张全屏

    /// 全屏沉浸 + 微呼吸（1.04x）+ 暗角 + DV 日期戳
    private func buildSingle(stage: UIView, current: URL, intervalMs: Int64, photoTimeMs: Int64) -> Bool {
        let iv = makeImageView(stage: stage)
        loadInto(iv, file: current)
        addVignetteCorners(stage: stage, intensity: 0.18)
        addBottomScrim(stage: stage, heightPt: 80, intensity: 0.25)
        addDateStamp(container: stage, timeMs: photoTimeMs)
        fadeIn(iv, duration: 0.4)
        buildKenBurnsAnimator(iv, intervalMs: intervalMs, zoomTo: 1.04, enableRotation: true, faceFile: current)
        return true
    }

    // MARK: - Ken Burns 电影推拉

    /// 有机推拉 1.14x + 微旋转 + 暗角 + DV 日期戳
    private func buildKenBurns(stage: UIView, current: URL, intervalMs: Int64, photoTimeMs: Int64) -> Bool {
        let iv = makeImageView(stage: stage)
        loadInto(iv, file: current)
        addVignetteCorners(stage: stage, intensity: 0.25)
        addBottomScrim(stage: stage, heightPt: 60, intensity: 0.15)
        addDateStamp(container: stage, timeMs: photoTimeMs)
        fadeIn(iv, duration: 0.4)
        buildKenBurnsAnimator(iv, intervalMs: intervalMs, zoomTo: 1.14, enableRotation: true, faceFile: current)
        return true
    }

    // MARK: - 拍立得卡片

    /// 宽白边卡片 + 确定性随机倾斜 + 手写体日期 + 掉落弹跳入场
    private func buildPolaroid(stage: UIView, current: URL, caption: String?) {
        let b = stage.bounds
        let outer: CGFloat = 48
        let card = UIView(frame: b.insetBy(dx: outer, dy: outer))
        card.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.backgroundColor = .white
        card.layer.cornerRadius = 4
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.35
        card.layer.shadowRadius = 20
        card.layer.shadowOffset = CGSize(width: 0, height: 8)
        stage.addSubview(card)

        // 照片区域（上边/左右 14pt 白边，底部 58pt 留白写字）
        let pad: CGFloat = 14
        let captionH: CGFloat = 58
        let photoFrame = CGRect(
            x: pad, y: pad,
            width: card.bounds.width - pad * 2,
            height: card.bounds.height - pad - captionH
        )
        let iv = UIImageView(frame: photoFrame)
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.layer.cornerRadius = 2
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        card.addSubview(iv)
        loadInto(iv, file: current)

        // 手写风日期
        let captionView = UILabel(frame: CGRect(
            x: pad, y: photoFrame.maxY,
            width: card.bounds.width - pad * 2, height: captionH
        ))
        captionView.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        captionView.text = caption ?? ""
        captionView.textColor = UIColor(argb: 0xFF5D4037)
        captionView.font = UIFont(name: "SnellRoundhand", size: 15)
            ?? UIFont.italicSystemFont(ofSize: 15)
        captionView.textAlignment = .center
        card.addSubview(captionView)

        // 确定性旋转（-4° ~ 4°）：同一张照片始终同一角度
        let seed = stableHash(current.lastPathComponent)
        let rotation = (-4 + CGFloat(seed % 9) * 0.88) * .pi / 180
        card.transform = CGAffineTransform(rotationAngle: rotation)

        // 掉落弹跳入场
        let finalTransform = card.transform
        card.alpha = 0
        card.transform = finalTransform
            .translatedBy(x: 0, y: -200)
            .scaledBy(x: 0.85, y: 0.85)
        pendingAnimations.append {
            UIView.animate(withDuration: 0.6, delay: 0,
                           usingSpringWithDamping: 0.55, initialSpringVelocity: 0.6,
                           options: [.curveEaseOut]) {
                card.alpha = 1
                card.transform = finalTransform
            }
        }
    }

    // MARK: - 回忆拼贴

    /**
     * 拼贴布局（v4 方向自适应，人脸居中）：
     * 竖屏 = 上大图（62%）+ 下方横排双小图；横屏 = 左大图（2/3）+ 右侧竖列双小图
     */
    private func buildCollage(stage: UIView, current: URL, upcoming: [URL]) {
        stage.backgroundColor = UIColor(argb: 0xFF1A1A1A)

        let portrait = isPortraitStage
        let root = LinearLayout(axis: portrait ? .vertical : .horizontal)
        root.frame = stage.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.padding = .init(top: 8, left: 8, bottom: 8, right: 8)
        stage.addSubview(root)

        let big = FaceCropImageView(cornerRadius: 10)
        big.layer.zPosition = 6

        if portrait {
            root.addWeighted(big, weight: 1.65)
        } else {
            root.addWeighted(big, weight: 2.0)
        }
        big.loadFaceCentered(file: current)

        var cells: [UIView] = [big]
        if !upcoming.isEmpty {
            let row = LinearLayout(axis: portrait ? .horizontal : .vertical)
            row.spacing = 6
            root.addWeighted(row, weight: 1.0)

            let first = FaceCropImageView(cornerRadius: 10)
            first.layer.zPosition = 4
            row.addWeighted(first, weight: 1)
            first.loadFaceCentered(file: upcoming[0])
            cells.append(first)

            if upcoming.count >= 2 {
                let second = FaceCropImageView(cornerRadius: 10)
                second.layer.zPosition = 4
                row.addWeighted(second, weight: 1)
                second.loadFaceCentered(file: upcoming[1])
                cells.append(second)
            }
        }

        addBottomScrim(stage: stage, heightPt: 60, intensity: 0.18)
        animateChildrenStaggered(cells, baseDelay: portrait ? 0.1 : 0.12)
    }

    // MARK: - 分屏对比

    /**
     * 对称分屏（v4 方向自适应）：竖屏上下 / 横屏左右。
     * 两格独立 Ken Burns（方向相反）+ 渐变发光中缝 + 各格 DV 时间戳（13pt/12pt）。
     */
    private func buildSplitScreen(
        stage: UIView,
        current: URL,
        upcoming: [UpcomingPhoto],
        intervalMs: Int64,
        photoTimeMs: Int64
    ) {
        stage.backgroundColor = UIColor(argb: 0xFF1A1A1A)

        // 无后续照片：退化为单张全屏
        if upcoming.isEmpty {
            let iv = FaceCropImageView(cornerRadius: 8)
            iv.frame = stage.bounds
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stage.addSubview(iv)
            iv.loadFaceCentered(file: current)
            addBottomScrim(stage: stage, heightPt: 90, intensity: 0.25)
            addDateStamp(container: stage, timeMs: photoTimeMs)
            return
        }

        let portrait = isPortraitStage
        let root = LinearLayout(axis: portrait ? .vertical : .horizontal)
        root.frame = stage.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.padding = .init(top: 6, left: 6, bottom: 6, right: 6)
        root.spacing = 3
        stage.addSubview(root)

        // 两格（各自包一层以叠加自己的 DV 日期戳）
        let firstCell = UIView()
        let secondCell = UIView()
        firstCell.layer.zPosition = 4
        secondCell.layer.zPosition = 4
        root.addWeighted(firstCell, weight: 1)
        // 中缝渐变发光分隔条
        let dividerColors = [
            UIColor.white.withAlphaComponent(0.06),
            UIColor.white.withAlphaComponent(0.38),
            UIColor.white.withAlphaComponent(0.06)
        ]
        let divider = GradientView(
            colors: dividerColors,
            startPoint: portrait ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0.5),
            endPoint: portrait ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 0.5)
        )
        root.addFixed(divider, size: 3)
        root.addWeighted(secondCell, weight: 1)

        func fillCell(_ cell: UIView, file: URL, timeMs: Int64, first: Bool) {
            let iv = FaceCropImageView(cornerRadius: 8)
            iv.frame = cell.bounds
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cell.addSubview(iv)
            iv.loadFaceCentered(file: file)
            addDateStamp(container: cell, timeMs: timeMs, sizePt: 13, marginPt: 12)

            // 独立 Ken Burns（两格方向相反）
            let duration = max(TimeInterval(intervalMs) * 1.2 / 1000.0, 2.4)
            let dir: CGFloat = first ? 1 : -1
            let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) {
                var t = CGAffineTransform.identity
                t = t.translatedBy(x: portrait ? 0 : -16 * dir, y: portrait ? -16 * dir : 0)
                t = t.scaledBy(x: 1.08, y: 1.08)
                t = t.rotated(by: dir * (CGFloat.random(in: 0...1) - 0.5) * .pi / 180)
                iv.transform = t
            }
            animators.append(animator)
            pendingAnimations.append { [weak animator] in animator?.startAnimation() }
        }

        fillCell(firstCell, file: current, timeMs: photoTimeMs, first: true)
        fillCell(secondCell, file: upcoming[0].file, timeMs: upcoming[0].timeMs, first: false)

        addBottomScrim(stage: stage, heightPt: 90, intensity: 0.25)
        root.alpha = 0
        pendingAnimations.append {
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut]) {
                root.alpha = 1
            }
        }
    }

    // MARK: - 胶片连放

    /**
     * 复古胶片（v4 方向自适应）：竖屏竖向胶卷（齿孔左右）两帧；横屏 35mm（齿孔上下）三帧。
     * 绝不重复填充：帧数 = 可用不重复照片数。
     */
    private func buildFilmstrip(stage: UIView, current: URL, upcoming: [URL]) {
        stage.backgroundColor = UIColor(argb: 0xFF1A1A1A)

        let portrait = isPortraitStage
        let maxFrames = portrait ? 2 : 3
        let photos = [current] + Array(upcoming.prefix(maxFrames - 1))

        let root = LinearLayout(axis: portrait ? .horizontal : .vertical)
        root.frame = stage.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(root)

        let strip = LinearLayout(axis: portrait ? .vertical : .horizontal)
        strip.spacing = 2
        strip.padding = portrait
            ? UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
            : UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)

        photos.enumerated().forEach { idx, file in
            let cell = UIView()
            strip.addWeighted(cell, weight: 1)
            let iv = UIImageView(frame: cell.bounds)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 3
            iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            cell.addSubview(iv)
            loadInto(iv, file: file)

            // 帧号标记（胶片编码风格）
            let label = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 14))
            label.font = UIFont(name: "Menlo", size: 10)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            label.text = "\(idx + 1)A"
            label.sizeToFit()
            label.frame.origin = CGPoint(x: cell.bounds.width - label.bounds.width - 6,
                                         y: cell.bounds.height - label.bounds.height - 4)
            label.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
            cell.addSubview(label)
        }

        if portrait {
            root.addFixed(makeFilmstripSideBar(), size: 28)
            root.addWeighted(strip, weight: 1)
            root.addFixed(makeFilmstripSideBar(), size: 28)
        } else {
            root.addFixed(makeFilmstripBar(), size: 28)
            root.addWeighted(strip, weight: 1)
            root.addFixed(makeFilmstripBar(), size: 28)
        }

        // 入场：竖屏从下往上卷动，横屏从左到右卷入
        root.alpha = 0
        let offset: CGFloat = 80
        if portrait {
            root.transform = CGAffineTransform(translationX: 0, y: offset)
        } else {
            root.transform = CGAffineTransform(translationX: offset, y: 0)
        }
        pendingAnimations.append {
            UIView.animate(withDuration: 0.4, delay: 0, options: [.curveEaseOut]) {
                root.alpha = 1
                root.transform = .identity
            }
        }
    }

    /// 横向胶片齿孔条（上下边缘）
    private func makeFilmstripBar() -> LinearLayout {
        let bar = LinearLayout(axis: .horizontal)
        bar.backgroundColor = UIColor(argb: 0xFF2A2A2A)
        bar.padding = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        bar.spacing = 0
        for i in 0..<8 {
            let hole = UIView()
            hole.backgroundColor = UIColor(argb: 0xFF1A1A1A)
            hole.layer.cornerRadius = 6
            bar.addWeighted(hole, weight: 1)
            hole.layer.cornerRadius = 6
            _ = i
        }
        // 固定齿孔尺寸：替换为均匀 12pt
        for sub in bar.subviews {
            sub.layer.cornerRadius = 6
        }
        return bar
    }

    /// 竖向胶片齿孔条（左右边缘）
    private func makeFilmstripSideBar() -> LinearLayout {
        let bar = LinearLayout(axis: .vertical)
        bar.backgroundColor = UIColor(argb: 0xFF2A2A2A)
        bar.padding = UIEdgeInsets(top: 16, left: 0, bottom: 16, right: 0)
        for _ in 0..<10 {
            let hole = UIView()
            hole.backgroundColor = UIColor(argb: 0xFF1A1A1A)
            hole.layer.cornerRadius = 6
            bar.addWeighted(hole, weight: 1)
        }
        return bar
    }

    // MARK: - 马赛克网格

    /**
     * 马赛克网格（v4 方向自适应）：竖屏 2×3，横屏 3×3。
     * 不重复填充：不足时缩减格子数量。波浪式入场从左上扩散。
     */
    private func buildMosaic(stage: UIView, current: URL, upcoming: [URL]) {
        stage.backgroundColor = UIColor(argb: 0xFF1A1A1A)

        let portrait = isPortraitStage
        let cols = portrait ? 2 : 3
        let maxCells = cols * 3
        let available = min(maxCells, 1 + upcoming.count)
        let photos = [current] + Array(upcoming.prefix(available - 1))
        let rows = (photos.count + cols - 1) / cols

        let root = LinearLayout(axis: .vertical)
        root.frame = stage.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.padding = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        root.spacing = 3
        stage.addSubview(root)

        for row in 0..<rows {
            let rowLl = LinearLayout(axis: .horizontal)
            rowLl.spacing = 3
            root.addWeighted(rowLl, weight: 1)
            for col in 0..<cols {
                let idx = row * cols + col
                guard idx < photos.count else { break }
                let iv = UIImageView(frame: .zero)
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.layer.cornerRadius = 5
                iv.layer.zPosition = 2
                rowLl.addWeighted(iv, weight: 1)
                loadInto(iv, file: photos[idx])

                // 波浪式交错入场（对角线扩散）
                let delay = 0.03 + Double(row + col) * 0.05
                iv.alpha = 0
                iv.transform = CGAffineTransform(translationX: 0, y: 15).scaledBy(x: 0.8, y: 0.8)
                pendingAnimations.append {
                    UIView.animate(withDuration: 0.35, delay: delay,
                                   usingSpringWithDamping: 0.62, initialSpringVelocity: 0.5,
                                   options: [.curveEaseOut]) {
                        iv.alpha = 1
                        iv.transform = .identity
                    }
                }
            }
        }
    }

    // MARK: - 电影遮幅

    /**
     * 2.35:1 电影宽银幕：上下遮幅 + 边缘羽化 + 四角暗角 + 胶片颗粒 + Ken Burns 1.10x。
     * DV 日期戳加在画面容器内（15pt/18pt）避开黑条。
     */
    private func buildCinematic(stage: UIView, current: URL, intervalMs: Int64, photoTimeMs: Int64) -> Bool {
        stage.backgroundColor = .black

        let barHeight: CGFloat = 56
        let container = UIView(frame: stage.bounds.insetBy(dx: 0, dy: barHeight))
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(container)

        let iv = UIImageView(frame: container.bounds)
        iv.contentMode = .scaleAspectFill
        iv.clipsToBounds = true
        iv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(iv)
        loadInto(iv, file: current)

        addDateStamp(container: container, timeMs: photoTimeMs, sizePt: 15, marginPt: 18)

        // 上下遮幅条（非纯黑，模拟胶片黑边）
        let topBar = UIView(frame: CGRect(x: 0, y: 0, width: stage.bounds.width, height: barHeight))
        topBar.backgroundColor = UIColor(argb: 0xFF0A0A0A)
        topBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        stage.addSubview(topBar)
        let bottomBar = UIView(frame: CGRect(x: 0, y: stage.bounds.height - barHeight,
                                             width: stage.bounds.width, height: barHeight))
        bottomBar.backgroundColor = UIColor(argb: 0xFF0A0A0A)
        bottomBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(bottomBar)

        // 边缘柔和渐变过渡
        let fadeTop = GradientView(colors: [.black, .clear],
                                   startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        fadeTop.frame = CGRect(x: 0, y: barHeight, width: stage.bounds.width, height: 20)
        fadeTop.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        stage.addSubview(fadeTop)
        let fadeBottom = GradientView(colors: [.clear, .black],
                                      startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        fadeBottom.frame = CGRect(x: 0, y: stage.bounds.height - barHeight - 20,
                                  width: stage.bounds.width, height: 20)
        fadeBottom.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(fadeBottom)

        addVignetteCorners(stage: stage, intensity: 0.35)

        // 极淡噪点纹理（对角渐变叠加近似）
        let grain = GradientView(
            colors: [
                UIColor.white.withAlphaComponent(0.012),
                .clear,
                UIColor.black.withAlphaComponent(0.008),
                .clear
            ],
            startPoint: .init(x: 0, y: 0), endPoint: .init(x: 1, y: 1)
        )
        grain.frame = stage.bounds
        grain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stage.addSubview(grain)

        fadeIn(iv, duration: 0.5)
        buildKenBurnsAnimator(iv, intervalMs: intervalMs, zoomTo: 1.10, enableRotation: true, faceFile: current)
        return true
    }

    // MARK: - iOS 回忆风格

    /**
     * MEMORIES v3：每张照片 Ken Burns 推拉 + 布局随机变化。
     * - 拼贴 10%（需 2 张后续，展示 3 张，无日期戳）
     * - 电影遮幅 20%（日期戳抬高 70pt 到黑条之上）
     * - 浅景深 5%（边缘极淡渐变）
     * - 微距放大 10%（1.25x）
     * 基于文件名确定性子随机：同一张照片始终同一种布局。
     */
    private func buildMemories(
        stage: UIView,
        current: URL,
        upcoming: [URL],
        intervalMs: Int64,
        photoTimeMs: Int64
    ) -> Bool {
        let seed = stableHash(current.lastPathComponent)
        let choice = CGFloat(seed % 1000) / 1000.0

        // 10% 拼贴（需要至少 2 张后续照片）
        if choice < 0.10, upcoming.count >= 2 {
            lastConsumedCount = 3
            buildMemoriesCollage(stage: stage, current: current, upcoming: upcoming)
            return false
        }

        let iv = makeImageView(stage: stage)
        loadInto(iv, file: current)

        let cinematic = choice >= 0.10 && choice < 0.30
        if cinematic {
            addMemoriesCinematicBars(stage: stage)
        }

        // 5% 浅景深虚化（边缘极淡渐变）
        if choice >= 0.30 && choice < 0.35 {
            let dof = GradientView(
                colors: [
                    UIColor.white.withAlphaComponent(0.03),
                    .clear,
                    .clear,
                    UIColor.black.withAlphaComponent(0.03)
                ],
                startPoint: .init(x: 0, y: 0), endPoint: .init(x: 1, y: 1)
            )
            dof.frame = stage.bounds
            dof.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            stage.addSubview(dof)
        }

        addVignetteCorners(stage: stage, intensity: 0.20)

        // DV 日期戳（电影遮幅变体抬高到黑条之上）
        addDateStamp(container: stage, timeMs: photoTimeMs, marginPt: cinematic ? 70 : 26)

        let zoomTo: CGFloat = choice >= 0.90 ? 1.25 : 1.10
        buildKenBurnsAnimator(iv, intervalMs: intervalMs, zoomTo: zoomTo, enableRotation: true, faceFile: current)
        return true
    }

    /// 回忆风格电影遮幅条（比 buildCinematic 轻量）
    private func addMemoriesCinematicBars(stage: UIView) {
        let barHeight: CGFloat = 60
        let w = stage.bounds.width

        let topBar = UIView(frame: CGRect(x: 0, y: 0, width: w, height: barHeight))
        topBar.backgroundColor = .black
        topBar.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        stage.addSubview(topBar)
        let fadeTop = GradientView(colors: [.black, .clear],
                                   startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        fadeTop.frame = CGRect(x: 0, y: barHeight, width: w, height: 16)
        fadeTop.autoresizingMask = [.flexibleWidth, .flexibleBottomMargin]
        stage.addSubview(fadeTop)

        let bottomBar = UIView(frame: CGRect(x: 0, y: stage.bounds.height - barHeight, width: w, height: barHeight))
        bottomBar.backgroundColor = .black
        bottomBar.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(bottomBar)
        let fadeBottom = GradientView(colors: [.clear, .black],
                                      startPoint: .init(x: 0.5, y: 0), endPoint: .init(x: 0.5, y: 1))
        fadeBottom.frame = CGRect(x: 0, y: stage.bounds.height - barHeight - 16, width: w, height: 16)
        fadeBottom.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
        stage.addSubview(fadeBottom)
    }

    /// 回忆风格拼贴（更柔和圆角，无日期叠加）
    private func buildMemoriesCollage(stage: UIView, current: URL, upcoming: [URL]) {
        stage.backgroundColor = .black

        let portrait = isPortraitStage
        let root = LinearLayout(axis: portrait ? .vertical : .horizontal)
        root.frame = stage.bounds
        root.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.padding = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        root.spacing = 4
        stage.addSubview(root)

        let big = FaceCropImageView(cornerRadius: 8)
        big.layer.zPosition = 6
        root.addWeighted(big, weight: portrait ? 1.65 : 2.0)
        big.loadFaceCentered(file: current)

        var cells: [UIView] = [big]
        if !upcoming.isEmpty {
            let area = LinearLayout(axis: portrait ? .horizontal : .vertical)
            area.spacing = 4
            root.addWeighted(area, weight: 1)

            let first = FaceCropImageView(cornerRadius: 8)
            first.layer.zPosition = 4
            area.addWeighted(first, weight: 1)
            first.loadFaceCentered(file: upcoming[0])
            cells.append(first)

            if upcoming.count >= 2 {
                let second = FaceCropImageView(cornerRadius: 8)
                second.layer.zPosition = 4
                area.addWeighted(second, weight: 1)
                second.loadFaceCentered(file: upcoming[1])
                cells.append(second)
            }
        }

        animateChildrenStaggered(cells, baseDelay: 0.15)
    }

    // MARK: - 辅助

    /// 稳定哈希（djb2）：进程间稳定（Swift hashValue 每次运行不同，不可用于确定性布局）
    private func stableHash(_ s: String) -> UInt64 {
        var hash: UInt64 = 5381
        for b in s.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(b)
        }
        return hash
    }
}
