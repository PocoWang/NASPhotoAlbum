import UIKit

/**
 * 时间段选择页（用于夜间休眠展示时段设置）。
 *
 * 两个 UIDatePicker（时:分），分别对应开始/结束时刻；
 * 结束回调将分钟数写回 SettingsStore。
 */
final class TimeRangePickerViewController: UIViewController {

    private let titleText: String
    private let startMinute: Int
    private let endMinute: Int
    private let onDone: (Int, Int) -> Void

    private var startPicker: UIDatePicker!
    private var endPicker: UIDatePicker!
    private var startLabel: UILabel!
    private var endLabel: UILabel!

    init(
        title: String,
        startMinute: Int,
        endMinute: Int,
        onDone: @escaping (Int, Int) -> Void
    ) {
        self.titleText = title
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private static func date(fromMinute minute: Int) -> Date {
        var comps = DateComponents()
        comps.hour = minute / 60
        comps.minute = minute % 60
        return Calendar.current.date(from: comps) ?? Date()
    }

    private static func minute(from date: Date) -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(argb: 0xFF14171C)
        title = titleText
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )

        func makeLabel(_ text: String) -> UILabel {
            let l = UILabel()
            l.text = text
            l.font = .systemFont(ofSize: 14, weight: .medium)
            l.textColor = UIColor(white: 1.0, alpha: 0.6)
            return l
        }

        let startLabel = makeLabel("展示开始时刻")
        let endLabel = makeLabel("展示结束时刻")
        self.startLabel = startLabel
        self.endLabel = endLabel

        startPicker = UIDatePicker()
        startPicker.datePickerMode = .time
        startPicker.date = TimeRangePickerViewController.date(fromMinute: startMinute)
        startPicker.setValue(UIColor.white, forKey: "textColor")

        endPicker = UIDatePicker()
        endPicker.datePickerMode = .time
        endPicker.date = TimeRangePickerViewController.date(fromMinute: endMinute)
        endPicker.setValue(UIColor.white, forKey: "textColor")

        view.addSubview(startLabel)
        view.addSubview(startPicker)
        view.addSubview(endLabel)
        view.addSubview(endPicker)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let top: CGFloat = {
            if #available(iOS 11.0, *) { return view.safeAreaInsets.top + 20 }
            return 84
        }()
        startLabel.frame = CGRect(x: 24, y: top, width: w - 48, height: 20)
        startPicker.frame = CGRect(x: 0, y: top + 24, width: w, height: 200)
        endLabel.frame = CGRect(x: 24, y: top + 236, width: w - 48, height: 20)
        endPicker.frame = CGRect(x: 0, y: top + 260, width: w, height: 200)
    }

    @objc private func doneTapped() {
        let s = TimeRangePickerViewController.minute(from: startPicker.date)
        let e = TimeRangePickerViewController.minute(from: endPicker.date)
        onDone(s, e)
        navigationController?.popViewController(animated: true)
    }
}

/**
 * 设置页（对应 Android 端 SettingsFragment + preferences.xml，分组一比一移植）。
 *
 * - NAS 连接：主机/端口/用户名/密码/域名/共享名（可选）+ 测试连接
 * - 照片目录：目录浏览器入口 + 包含子目录开关
 * - 缓存：上限设置（变更即时 LRU 淘汰/补下载）+ 清空缓存
 * - 扫描：周期 + 立即扫描
 * - 播放：展示模式/顺序/间隔/过渡动画
 * - 时钟：样式 + 外观弹窗入口
 * - 夜间休眠：开关 + 三种调度类型 + 对应时段设置
 * - 维护：重置播放位置
 *
 * 注意：sections 中存储的闭包一律捕获局部 store / [weak self]，
 * 避免页面级强引用循环导致控制器无法释放。
 */
final class SettingsViewController: UITableViewController {

    // MARK: - 行模型

    private enum Row {
        case text(label: String, placeholder: String, secure: Bool, keyboard: UIKeyboardType,
                  key: String)
        case nav(label: String, detail: () -> String, onTap: () -> Void)
        case toggle(label: String, get: () -> Bool, set: (Bool) -> Void)
        case option(label: String, detail: () -> String, onTap: () -> Void)
        case button(label: String, destructive: Bool, onTap: () -> Void)
    }

    private struct Section {
        var title: String
        var footer: String?
        var rows: [Row]
    }

    private var sections: [Section] = []

    // MARK: - 生命周期

    init() { super.init(style: .grouped) }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        view.backgroundColor = UIColor(argb: 0xFF101216)
        tableView.backgroundColor = UIColor(argb: 0xFF101216)
        tableView.separatorColor = UIColor(white: 1.0, alpha: 0.08)
        tableView.rowHeight = 52
        rebuildSections()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 从目录浏览器/时间选择页返回后刷新显示值
        rebuildSections()
        tableView.reloadData()
    }

    // MARK: - 分组构建

    /// UserDefaults 直读（NAS 文本字段；静态方法避免闭包捕获 self）
    private static func def(_ key: String) -> String {
        return UserDefaults.standard.string(forKey: key) ?? ""
    }

    private static func setDef(_ key: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private func rebuildSections() {
        // 局部引用，闭包捕获 store 而非 self（避免引用循环）
        let store = AppServices.shared.settings
        weak var weakSelf = self
        sections.removeAll()

        // 1. NAS 连接
        sections.append(Section(title: "NAS 连接（SMB）", footer: "共享名可留空：将从所选目录路径自动解析。", rows: [
            .text(label: "主机地址", placeholder: "如 192.168.1.10", secure: false,
                  keyboard: .default, key: SettingsStore.keyNasHost),
            .text(label: "端口", placeholder: "445", secure: false,
                  keyboard: .numberPad, key: SettingsStore.keyNasPort),
            .text(label: "用户名", placeholder: "NAS 账号", secure: false,
                  keyboard: .default, key: SettingsStore.keyNasUsername),
            .text(label: "密码", placeholder: "NAS 密码", secure: true,
                  keyboard: .default, key: SettingsStore.keyNasPassword),
            .text(label: "域名（可选）", placeholder: "一般留空", secure: false,
                  keyboard: .default, key: SettingsStore.keyNasDomain),
            .text(label: "共享名（可选）", placeholder: "留空自动解析", secure: false,
                  keyboard: .default, key: SettingsStore.keyShareName),
            .button(label: "测试连接", destructive: false, onTap: { weakSelf?.testConnection() })
        ]))

        // 2. 照片目录
        sections.append(Section(title: "照片目录", footer: nil, rows: [
            .nav(label: "选择照片目录",
                 detail: {
                     let n = store.getSelectedDirs().count
                     return n == 0 ? "未选择" : "已选 \(n) 个"
                 },
                 onTap: { weakSelf?.openDirBrowser() }),
            .toggle(label: "包含子目录",
                    get: { store.includeSubdir },
                    set: { store.includeSubdir = $0 })
        ]))

        // 3. 缓存
        sections.append(Section(
            title: "缓存",
            footer: "缓存上限变更后：超出部分按最久未播优先淘汰；未满则继续后台下载。",
            rows: [
                .option(label: "缓存上限",
                        detail: { formatSize(store.getCacheSizeBytes()) },
                        onTap: { weakSelf?.pickCacheSize() }),
                .button(label: "清空缓存（保留索引）", destructive: false,
                        onTap: { weakSelf?.clearCache() })
            ]))

        // 4. 扫描
        sections.append(Section(title: "扫描", footer: nil, rows: [
            .option(label: "扫描周期",
                    detail: { store.getScanPeriod().display },
                    onTap: { weakSelf?.pickScanPeriod() }),
            .button(label: "立即扫描（清空缓存后重新下载）", destructive: false,
                    onTap: { weakSelf?.scanNow() })
        ]))

        // 5. 播放
        sections.append(Section(title: "播放", footer: nil, rows: [
            .option(label: "展示模式",
                    detail: { store.getDisplayMode().display },
                    onTap: { weakSelf?.pickDisplayMode() }),
            .option(label: "播放顺序",
                    detail: { store.getPlayOrder().display },
                    onTap: { weakSelf?.pickPlayOrder() }),
            .option(label: "播放间隔",
                    detail: { "\(store.getPlayIntervalMs() / 1000) 秒" },
                    onTap: { weakSelf?.pickPlayInterval() }),
            .option(label: "过渡动画",
                    detail: { store.getTransitionType().display },
                    onTap: { weakSelf?.pickTransition() })
        ]))

        // 6. 时钟
        sections.append(Section(title: "时钟", footer: nil, rows: [
            .option(label: "时钟样式",
                    detail: { store.getClockStyle().display },
                    onTap: { weakSelf?.pickClockStyle() }),
            .nav(label: "时钟外观", detail: { "字体 · 颜色 · 位置" },
                 onTap: { weakSelf?.openClockAppearance() })
        ]))

        // 7. 夜间休眠
        sections.append(buildNightSection(store: store, weakSelf: weakSelf))

        // 8. 维护
        sections.append(Section(title: "维护", footer: nil, rows: [
            .button(label: "重置播放位置（清空 LRU 记录）", destructive: false, onTap: { [weak self] in
                guard let self = self else { return }
                DispatchQueue.global(qos: .utility).async {
                    AppServices.shared.photoRepository.resetAllPlayedTime()
                }
                self.toast("已重置")
            })
        ]))
    }

    private func buildNightSection(store: SettingsStore, weakSelf: SettingsViewController?) -> Section {
        var rows: [Row] = [
            .toggle(label: "夜间休眠",
                    get: { store.nightModeEnabled },
                    set: { on in
                        store.nightModeEnabled = on
                        weakSelf?.rebuildSections()
                        weakSelf?.tableView.reloadData()
                    })
        ]
        guard store.nightModeEnabled else {
            return Section(title: "夜间休眠", footer: "开启后，非展示时段进入黑屏静默，到点自动恢复。", rows: rows)
        }

        rows.append(.option(label: "调度类型",
                            detail: { store.getNightScheduleType().display },
                            onTap: { weakSelf?.pickNightType() }))

        func rangeRow(_ label: String, getS: @escaping () -> Int, getE: @escaping () -> Int,
                      setRange: @escaping (Int, Int) -> Void) -> Row {
            return .nav(label: label,
                        detail: {
                            "\(NightSchedule.formatMinute(getS())) ~ \(NightSchedule.formatMinute(getE()))"
                        },
                        onTap: {
                            weakSelf?.navigationController?.pushViewController(
                                TimeRangePickerViewController(
                                    title: label,
                                    startMinute: getS(),
                                    endMinute: getE(),
                                    onDone: { s, e in
                                        setRange(s, e)
                                        weakSelf?.rebuildSections()
                                        weakSelf?.tableView.reloadData()
                                    }
                                ),
                                animated: true
                            )
                        })
        }

        switch store.getNightScheduleType() {
        case .unified:
            rows.append(rangeRow(
                "展示时段",
                getS: { store.getNightModeStartMinute() },
                getE: { store.getNightModeEndMinute() },
                setRange: {
                    store.setNightModeStartMinute($0)
                    store.setNightModeEndMinute($1)
                }
            ))
        case .workRest:
            rows.append(rangeRow(
                "工作日时段",
                getS: { store.getNightWorkdayStartMinute() },
                getE: { store.getNightWorkdayEndMinute() },
                setRange: {
                    store.setNightWorkdayStartMinute($0)
                    store.setNightWorkdayEndMinute($1)
                }
            ))
            rows.append(rangeRow(
                "休息日时段（周末+节假日）",
                getS: { store.getNightRestdayStartMinute() },
                getE: { store.getNightRestdayEndMinute() },
                setRange: {
                    store.setNightRestdayStartMinute($0)
                    store.setNightRestdayEndMinute($1)
                }
            ))
        case .perDay:
            let names = [1: "周一", 2: "周二", 3: "周三", 4: "周四", 5: "周五", 6: "周六", 7: "周日"]
            for day in 1...7 {
                let name = names[day] ?? ""
                rows.append(rangeRow(
                    name,
                    getS: { store.getNightDayStart(day) },
                    getE: { store.getNightDayEnd(day) },
                    setRange: { s, e in
                        store.setNightDayStart(day, minute: s)
                        store.setNightDayEnd(day, minute: e)
                    }
                ))
            }
        }
        return Section(
            title: "夜间休眠",
            footer: "时段语义：[开始, 结束) 为展示时间，其余黑屏静默；开始=结束 表示全天展示；支持跨午夜（如 20:00 ~ 07:00）。",
            rows: rows
        )
    }

    // MARK: - UITableViewDataSource / Delegate

    override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sections[section].rows.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: "cell")
        cell.backgroundColor = UIColor(argb: 0xFF1B1F26)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 16)
        cell.textLabel?.numberOfLines = 1
        cell.textLabel?.textAlignment = .natural
        cell.detailTextLabel?.textColor = UIColor(white: 1.0, alpha: 0.45)
        cell.detailTextLabel?.font = .systemFont(ofSize: 14)
        cell.selectionStyle = .none
        cell.accessoryView = nil
        cell.accessoryType = .none

        switch row {
        case .text(let label, let placeholder, let secure, _, let key):
            cell.textLabel?.text = label
            let value = SettingsViewController.def(key)
            cell.detailTextLabel?.text =
                (secure && !value.isEmpty) ? "••••••" : (value.isEmpty ? placeholder : value)
            cell.accessoryType = .disclosureIndicator

        case .nav(let label, let detail, _):
            cell.textLabel?.text = label
            cell.detailTextLabel?.text = detail()
            cell.accessoryType = .disclosureIndicator

        case .toggle(let label, let get, _):
            cell.textLabel?.text = label
            let sw = UISwitch()
            sw.isOn = get()
            sw.onTintColor = UIColor(argb: 0xFFE8B64C)
            sw.addTarget(self, action: #selector(handleSwitch(_:)), for: .valueChanged)
            cell.accessoryView = sw

        case .option(let label, let detail, _):
            cell.textLabel?.text = label
            cell.detailTextLabel?.text = detail()
            cell.accessoryType = .disclosureIndicator

        case .button(let label, let destructive, _):
            cell.textLabel?.text = label
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.textColor = destructive
                ? UIColor(argb: 0xFFFF6E6E)
                : UIColor(argb: 0xFFE8B64C)

        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        let row = sections[indexPath.section].rows[indexPath.row]
        switch row {
        case .text(let label, let placeholder, let secure, let keyboard, let key):
            editText(title: label, placeholder: placeholder, secure: secure,
                     keyboard: keyboard, current: SettingsViewController.def(key)) { value in
                SettingsViewController.setDef(key, value)
                tableView.reloadRows(at: [indexPath], with: .none)
            }
        case .nav(_, _, let onTap), .option(_, _, let onTap):
            onTap()
        case .button(_, _, let onTap):
            onTap()
        case .toggle:
            break
        }
    }

    @objc private func handleSwitch(_ sender: UISwitch) {
        // switch 挂在 cell.contentView 上，需向上找到 UITableViewCell
        var responder: UIView? = sender
        while let v = responder, !(v is UITableViewCell) {
            responder = v.superview
        }
        if let cell = responder as? UITableViewCell,
           let indexPath = tableView.indexPath(for: cell) {
            let row = sections[indexPath.section].rows[indexPath.row]
            if case .toggle(_, _, let set) = row {
                set(sender.isOn)
            }
        }
    }

    // MARK: - 输入与选择

    private func editText(
        title: String,
        placeholder: String,
        secure: Bool,
        keyboard: UIKeyboardType,
        current: String,
        completion: @escaping (String) -> Void
    ) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = placeholder
            tf.text = current
            tf.isSecureTextEntry = secure
            tf.keyboardType = keyboard
            tf.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "保存", style: .default) { _ in
            let text = alert.textFields?.first?.text ?? ""
            completion(text)
        })
        present(alert, animated: true, completion: nil)
    }

    /// 通用单选弹窗（对应 Android ListPreference）
    private func pickOption<T>(
        title: String,
        options: [T],
        current: T,
        display: (T) -> String,
        onPick: @escaping (T) -> Void
    ) where T: Equatable {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for opt in options {
            let name = display(opt) + (opt == current ? "  ✓" : "")
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in
                onPick(opt)
                self.rebuildSections()
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        present(alert, animated: true, completion: nil)
    }

    private func pickCacheSize() {
        let options: [Int64] = [512 * 1024 * 1024, 1 << 30, 2 << 30, 4 << 30, 8 << 30]
        pickOption(
            title: "缓存上限",
            options: options,
            current: AppServices.shared.settings.getCacheSizeBytes(),
            display: { formatSize($0) }
        ) { [weak self] bytes in
            guard let self = self else { return }
            self.settingsRef.setCacheSizeBytes(bytes)
            self.onCacheSizeChanged()
        }
    }

    private func pickScanPeriod() {
        pickOption(
            title: "扫描周期",
            options: ScanPeriod.allCases,
            current: AppServices.shared.settings.getScanPeriod(),
            display: { $0.display }
        ) { AppServices.shared.settings.setScanPeriod($0) }
    }

    private func pickDisplayMode() {
        pickOption(
            title: "展示模式",
            options: DisplayMode.allCases,
            current: AppServices.shared.settings.getDisplayMode(),
            display: { $0.display }
        ) { AppServices.shared.settings.setDisplayMode($0) }
    }

    private func pickPlayOrder() {
        pickOption(
            title: "播放顺序",
            options: PlayOrder.allCases,
            current: AppServices.shared.settings.getPlayOrder(),
            display: { $0.display }
        ) { AppServices.shared.settings.setPlayOrder($0) }
    }

    private func pickPlayInterval() {
        let options: [Int64] = [3000, 5000, 8000, 10000, 15000, 30000, 60000]
        pickOption(
            title: "播放间隔",
            options: options,
            current: AppServices.shared.settings.getPlayIntervalMs(),
            display: { "\($0 / 1000) 秒" }
        ) { AppServices.shared.settings.setPlayIntervalMs($0) }
    }

    private func pickTransition() {
        pickOption(
            title: "过渡动画",
            options: TransitionType.allCases,
            current: AppServices.shared.settings.getTransitionType(),
            display: { $0.display }
        ) { AppServices.shared.settings.setTransitionType($0) }
    }

    private func pickClockStyle() {
        pickOption(
            title: "时钟样式",
            options: ClockStyle.allCases,
            current: AppServices.shared.settings.getClockStyle(),
            display: { $0.display }
        ) { AppServices.shared.settings.setClockStyle($0) }
    }

    private func pickNightType() {
        pickOption(
            title: "调度类型",
            options: NightScheduleType.allCases,
            current: AppServices.shared.settings.getNightScheduleType(),
            display: { $0.display }
        ) { [weak self] type in
            AppServices.shared.settings.setNightScheduleType(type)
            self?.rebuildSections()
            self?.tableView.reloadData()
        }
    }

    // MARK: - 导航

    private func openDirBrowser() {
        navigationController?.pushViewController(DirBrowserViewController(), animated: true)
    }

    private func openClockAppearance() {
        present(ClockAppearanceViewController(), animated: true, completion: nil)
    }

    /// 便捷引用（避免与闭包局部 store 命名冲突）
    private var settingsRef: SettingsStore { return AppServices.shared.settings }

    // MARK: - 操作

    private func testConnection() {
        guard let config = settingsRef.getNasConfig() else {
            toast("请先填写主机与用户名")
            return
        }
        toast("正在连接…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AppServices.shared.nasRepository.testConnection(config)
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.toast("连接成功 ✓")
                case .failure(let error):
                    self?.toast("连接失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /** 缓存上限变更：取消旧下载 → 超限 LRU 淘汰 / 未满补下载 */
    private func onCacheSizeChanged() {
        let scanCoordinator = AppServices.shared.scanCoordinator
        scanCoordinator.cancelDownload()
        DispatchQueue.global(qos: .utility).async {
            AppServices.shared.cacheManager.evictIfNeeded()
            scanCoordinator.downloadNow()
            DispatchQueue.main.async { [weak self] in
                self?.rebuildSections()
                self?.tableView.reloadData()
            }
        }
    }

    private func clearCache() {
        let alert = UIAlertController(
            title: "清空缓存",
            message: "将删除已下载的原图（索引保留），后台会按新顺序重新下载。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "清空", style: .destructive) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.global(qos: .utility).async {
                AppServices.shared.cacheManager.clearOriginalCacheOnly()
                AppServices.shared.scanCoordinator.downloadNow()
            }
            self.toast("已清空，后台重新下载中")
        })
        present(alert, animated: true, completion: nil)
    }

    private func scanNow() {
        guard settingsRef.isConfigured else {
            toast("请先填写 NAS 连接信息")
            return
        }
        AppServices.shared.scanCoordinator.scanNow(clearCache: true) { [weak self] result in
            switch result {
            case .success(let r):
                self?.toast("扫描完成：\(r.total) 张照片")
            case .failure(let error):
                self?.toast("扫描失败：\(error.localizedDescription)")
            }
        }
        toast("正在扫描…")
    }

    // MARK: - 小组件

    private func toast(_ text: String) {
        let alert = UIAlertController(title: text, message: nil, preferredStyle: .alert)
        present(alert, animated: true) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                alert.dismiss(animated: true, completion: nil)
            }
        }
    }
}
