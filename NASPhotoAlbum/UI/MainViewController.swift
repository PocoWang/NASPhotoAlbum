import UIKit

/**
 * 首页（对应 Android 端 MainFragment）。
 *
 * - 状态卡片：NAS 连接信息 / 照片总数 / 已缓存数 / 缓存空间进度
 * - 播放：进入幻灯片
 * - 立即扫描：清空原图缓存 → 扫描 NAS 更新索引 → 随机下载补缓存
 * - 下拉刷新：增量同步（不清空缓存）
 */
final class MainViewController: UIViewController {

    private let settings = AppServices.shared.settings
    private let scanCoordinator = AppServices.shared.scanCoordinator
    private let cacheManager = AppServices.shared.cacheManager

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentView = UIView()

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let btnSettings = UIButton(type: .system)

    private let statusCard = UIView()
    private let nasIconLabel = UILabel()
    private let nasHostLabel = UILabel()
    private let nasStateLabel = UILabel()

    private let statRow = UIView()

    private let cacheTitleLabel = UILabel()
    private let cacheValueLabel = UILabel()
    private let cacheBarBack = UIView()
    private let cacheBarFill = UIView()

    private let btnPlay = UIButton(type: .system)
    private let btnScan = UIButton(type: .system)
    private let scanSpinner = UIActivityIndicatorView(activityIndicatorStyle: .white)
    private let scanHintLabel = UILabel()

    // MARK: - 生命周期

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(argb: 0xFF101216)
        navigationController?.setNavigationBarHidden(true, animated: false)
        buildUI()
        observeChanges()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStats()
    }

    private func observeChanges() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(handleDataChange),
            name: Database.photoIndexDidChange, object: nil
        )
        nc.addObserver(
            self, selector: #selector(handleDataChange),
            name: ScanCoordinator.workStateDidChange, object: nil
        )
    }

    @objc private func handleDataChange() {
        refreshStats()
    }

    // MARK: - UI 构建

    private func buildUI() {
        automaticallyAdjustsScrollViewInsets = false
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.alwaysBounceVertical = true
        scrollView.delegate = self
        view.addSubview(scrollView)

        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        refresh.tintColor = UIColor(argb: 0xFFE8B64C)
        scrollView.refreshControl = refresh

        contentView.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 0)
        scrollView.addSubview(contentView)

        // 顶部标题区
        titleLabel.text = "NAS 相册"
        titleLabel.font = UIFont.systemFont(ofSize: 34, weight: .bold)
        titleLabel.textColor = .white
        contentView.addSubview(titleLabel)

        subtitleLabel.text = "家庭照片 · 电子相框"
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = UIColor(white: 1.0, alpha: 0.45)
        contentView.addSubview(subtitleLabel)

        btnSettings.setTitle("⚙", for: .normal)
        btnSettings.titleLabel?.font = .systemFont(ofSize: 26)
        btnSettings.setTitleColor(UIColor(white: 1.0, alpha: 0.8), for: .normal)
        btnSettings.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        contentView.addSubview(btnSettings)

        // 状态卡片
        statusCard.backgroundColor = UIColor(argb: 0xFF1B1F26)
        statusCard.layer.cornerRadius = 20
        statusCard.layer.shadowColor = UIColor.black.cgColor
        statusCard.layer.shadowOpacity = 0.35
        statusCard.layer.shadowRadius = 16
        statusCard.layer.shadowOffset = CGSize(width: 0, height: 8)
        contentView.addSubview(statusCard)

        nasIconLabel.text = "🏠"
        nasIconLabel.font = .systemFont(ofSize: 34)
        statusCard.addSubview(nasIconLabel)

        nasHostLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        nasHostLabel.textColor = .white
        statusCard.addSubview(nasHostLabel)

        nasStateLabel.font = .systemFont(ofSize: 12)
        nasStateLabel.textColor = UIColor(argb: 0xFF8BC34A)
        statusCard.addSubview(nasStateLabel)

        statRow.spacing = 12
        statusCard.addSubview(statRow)
        statRow.addSubview(buildStatBlock(title: "照片总数", tag: 100))
        statRow.addSubview(buildStatBlock(title: "已缓存", tag: 101))
        statRow.addSubview(buildStatBlock(title: "实况照片", tag: 102))

        // 缓存空间进度
        cacheTitleLabel.text = "缓存空间"
        cacheTitleLabel.font = .systemFont(ofSize: 13)
        cacheTitleLabel.textColor = UIColor(white: 1.0, alpha: 0.5)
        statusCard.addSubview(cacheTitleLabel)

        cacheValueLabel.font = .systemFont(ofSize: 13, weight: .medium)
        cacheValueLabel.textColor = UIColor(argb: 0xFFE8B64C)
        cacheValueLabel.textAlignment = .right
        statusCard.addSubview(cacheValueLabel)

        cacheBarBack.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        cacheBarBack.layer.cornerRadius = 4
        statusCard.addSubview(cacheBarBack)

        cacheBarFill.backgroundColor = UIColor(argb: 0xFFE8B64C)
        cacheBarFill.layer.cornerRadius = 4
        cacheBarBack.addSubview(cacheBarFill)

        // 播放按钮
        btnPlay.backgroundColor = UIColor(argb: 0xFFE8B64C)
        btnPlay.setTitle("▶  开始播放", for: .normal)
        btnPlay.setTitleColor(UIColor(argb: 0xFF2A2113), for: .normal)
        btnPlay.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        btnPlay.layer.cornerRadius = 26
        btnPlay.clipsToBounds = true
        btnPlay.addTarget(self, action: #selector(startSlideshow), for: .touchUpInside)
        contentView.addSubview(btnPlay)

        // 立即扫描
        btnScan.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
        btnScan.setTitle("⟳  立即扫描", for: .normal)
        btnScan.setTitleColor(.white, for: .normal)
        btnScan.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        btnScan.layer.cornerRadius = 26
        btnScan.layer.borderWidth = 1
        btnScan.layer.borderColor = UIColor(white: 1.0, alpha: 0.16).cgColor
        btnScan.addTarget(self, action: #selector(scanNow), for: .touchUpInside)
        contentView.addSubview(btnScan)

        scanSpinner.color = UIColor(argb: 0xFFE8B64C)
        scanSpinner.hidesWhenStopped = true
        contentView.addSubview(scanSpinner)

        scanHintLabel.font = .systemFont(ofSize: 12)
        scanHintLabel.textColor = UIColor(white: 1.0, alpha: 0.4)
        scanHintLabel.textAlignment = .center
        scanHintLabel.numberOfLines = 0
        contentView.addSubview(scanHintLabel)

        view.setNeedsLayout()
    }

    private func buildStatBlock(title: String, tag: Int) -> UIView {
        let block = UIView()
        block.backgroundColor = UIColor(white: 1.0, alpha: 0.05)
        block.layer.cornerRadius = 14
        block.tag = tag

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = UIColor(white: 1.0, alpha: 0.45)
        titleLabel.textAlignment = .center
        block.addSubview(titleLabel)

        let valueLabel = UILabel()
        valueLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 26, weight: .bold)
        valueLabel.textColor = .white
        valueLabel.textAlignment = .center
        valueLabel.tag = 200
        block.addSubview(valueLabel)
        return block
    }

    // MARK: - 布局

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let pad: CGFloat = 22

        let cardTop: CGFloat = 116
        let cardWidth = w - pad * 2
        let cardHeight: CGFloat = 236
        statusCard.frame = CGRect(x: pad, y: cardTop, width: cardWidth, height: cardHeight)

        nasIconLabel.frame = CGRect(x: 20, y: 20, width: 44, height: 44)
        nasHostLabel.frame = CGRect(x: 74, y: 22, width: cardWidth - 100, height: 24)
        nasStateLabel.frame = CGRect(x: 74, y: 48, width: cardWidth - 100, height: 16)

        statRow.frame = CGRect(x: 16, y: 80, width: cardWidth - 32, height: 74)
        for sub in statRow.subviews {
            let idx = statRow.subviews.firstIndex(of: sub) ?? 0
            let slot = (cardWidth - 32 - 24) / 3
            sub.frame = CGRect(x: CGFloat(idx) * (slot + 12), y: 0, width: slot, height: 74)
            if let titleLabel = sub.subviews.first(where: { $0 is UILabel && $0.tag == 0 }) as? UILabel {
                titleLabel.frame = CGRect(x: 6, y: 10, width: sub.bounds.width - 12, height: 16)
            }
            if let valueLabel = sub.viewWithTag(200) {
                valueLabel.frame = CGRect(x: 6, y: 30, width: sub.bounds.width - 12, height: 34)
            }
        }

        cacheTitleLabel.frame = CGRect(x: 20, y: 168, width: 100, height: 16)
        cacheValueLabel.frame = CGRect(x: cardWidth - 180, y: 168, width: 160, height: 16)
        cacheBarBack.frame = CGRect(x: 20, y: 192, width: cardWidth - 40, height: 8)

        titleLabel.frame = CGRect(x: pad, y: 56, width: w - pad * 2 - 60, height: 42)
        subtitleLabel.frame = CGRect(x: pad, y: 100, width: w - pad * 2, height: 18)
        btnSettings.frame = CGRect(x: w - 64, y: 56, width: 44, height: 44)

        let playY = cardTop + cardHeight + 24
        btnPlay.frame = CGRect(x: pad, y: playY, width: cardWidth, height: 54)
        btnScan.frame = CGRect(x: pad, y: playY + 70, width: cardWidth, height: 54)

        scanSpinner.frame = CGRect(x: pad + 24, y: playY + 70 + 15, width: 24, height: 24)
        scanHintLabel.frame = CGRect(
            x: pad, y: playY + 136, width: cardWidth, height: 34
        )
        let contentHeight = playY + 180
        contentView.frame = CGRect(x: 0, y: 0, width: w, height: contentHeight)
        scrollView.contentSize = CGSize(width: w, height: contentHeight + 40)
    }

    // MARK: - 数据刷新

    private func refreshStats() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let stats = self.cacheManager.currentStats()
            let liveCount = AppServices.shared.database.livePhotoCount()
            DispatchQueue.main.async {
                self.apply(stats: stats, liveCount: liveCount)
            }
        }
    }

    private func apply(stats: CacheStats, liveCount: Int) {
        // NAS 信息
        if let config = settings.getNasConfig() {
            nasHostLabel.text = "\(config.host):\(config.port)"
            nasStateLabel.textColor = UIColor(argb: 0xFF8BC34A)
            let dirCount = settings.getSelectedDirs().count
            nasStateLabel.text = "已连接 · 已选 \(dirCount) 个目录"
        } else {
            nasHostLabel.text = "未配置 NAS"
            nasStateLabel.textColor = UIColor(argb: 0xFFFF8A65)
            nasStateLabel.text = "请先在设置中连接 NAS"
        }

        // 统计块
        if let total = statRow.viewWithTag(100)?.viewWithTag(200) as? UILabel {
            total.text = "\(stats.totalPhotos)"
        }
        if let cached = statRow.viewWithTag(101)?.viewWithTag(200) as? UILabel {
            cached.text = "\(stats.cachedPhotos)"
        }
        if let live = statRow.viewWithTag(102)?.viewWithTag(200) as? UILabel {
            live.text = "\(liveCount)"
        }

        // 缓存空间
        cacheValueLabel.text = "\(formatSize(stats.usedBytes)) / \(formatSize(stats.limitBytes))"
        lastBarRatio = CGFloat(min(max(stats.usedRatio, 0), 1))
        layoutCacheBar()

        // 扫描状态
        let busy = scanCoordinator.isScanning || scanCoordinator.isDownloading
        scanSpinner.isHidden = !busy
        if busy { scanSpinner.startAnimating() } else { scanSpinner.stopAnimating() }
        btnScan.alpha = busy ? 0.55 : 1.0
        btnScan.isUserInteractionEnabled = !busy
        if scanCoordinator.isScanning {
            scanHintLabel.text = "正在扫描 NAS 目录…"
        } else if scanCoordinator.isDownloading {
            scanHintLabel.text = "正在下载照片到本地缓存…"
        } else {
            scanHintLabel.text = nil
        }
    }

    private var lastBarRatio: CGFloat = 0

    /** 按比例刷新缓存进度条（布局未就绪时由 viewWillLayoutSubviews 再算） */
    private func layoutCacheBar() {
        guard cacheBarBack.bounds.width > 0 else { return }
        cacheBarFill.frame = CGRect(
            x: 0, y: 0,
            width: max(8, cacheBarBack.bounds.width * lastBarRatio),
            height: cacheBarBack.bounds.height
        )
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        layoutCacheBar()
    }

    // MARK: - 交互

    @objc private func startSlideshow() {
        let vc = SlideshowViewController()
        vc.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(vc, animated: true)
    }

    @objc private func openSettings() {
        let vc = SettingsViewController()
        navigationController?.pushViewController(vc, animated: true)
    }

    /** 立即扫描：清空原图缓存 → 扫描 → 随机下载（对应 Android scanNow(clearCache=true)） */
    @objc private func scanNow() {
        guard settings.isConfigured else {
            showAlert(title: "未配置 NAS", message: "请先在设置中填写 NAS 连接信息")
            return
        }
        scanCoordinator.scanNow(clearCache: true) { [weak self] result in
            switch result {
            case .success(let r):
                self?.showAlert(
                    title: "扫描完成",
                    message: "照片总数 \(r.total) 张（新增 \(r.added)，移除 \(r.removed)）\n后台正在下载原图…"
                )
            case .failure(let error):
                self?.showAlert(title: "扫描失败", message: error.localizedDescription)
            }
        }
        refreshStats()
    }

    /** 下拉刷新：增量补缓存（不清空已有缓存） */
    @objc private func pullToRefresh() {
        if settings.isConfigured {
            scanCoordinator.scanNow(clearCache: false) { [weak self] _ in
                self?.scrollView.refreshControl?.endRefreshing()
                self?.refreshStats()
            }
        } else {
            scrollView.refreshControl?.endRefreshing()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        present(alert, animated: true, completion: nil)
    }
}

extension MainViewController: UIScrollViewDelegate {
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        refreshStats()
    }
}
