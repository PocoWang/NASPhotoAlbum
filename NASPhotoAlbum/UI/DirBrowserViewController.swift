import UIKit

/**
 * NAS 目录浏览器（对应 Android 端 DirBrowserFragment + DirBrowserViewModel）。
 *
 * 交互（一比一移植）：
 * - 首屏：列出 NAS 上所有共享名，点击选择共享进入其根目录
 * - 点击目录项 → 进入下一级
 * - 长按目录项 → 切换该目录选中状态
 * - "返回上一级" → 回到父目录（根目录不可再上）
 * - "选择当前目录" → 将当前目录加入已选
 * - 已选 chips 上的 ✗ → 移除该已选目录
 * - "包含子目录"开关 → 是否递归扫描
 * - "保存" → 持久化 selectedDirs 并返回
 */
final class DirBrowserViewController: UITableViewController {

    private let settings = AppServices.shared.settings
    private let nasRepository = AppServices.shared.nasRepository

    // MARK: - 状态（对应 BrowserUiState）

    private var shareName: String = ""          // 当前共享（空 = 共享选择屏）
    private var currentPath: String = "/"       // 共享内当前路径
    private var items: [NasDirNode] = []        // 当前目录的子目录（或共享列表）
    private var selectedDirs: Set<String> = []  // 已选目录（含共享名的完整路径）
    private var isLoading = false
    private var errorMessage: String?

    private var btnParent: UIBarButtonItem!
    private var btnConfirm: UIBarButtonItem!
    private var btnAddCurrent: UIBarButtonItem!
    private var switchSubdir: UISwitch!
    private var chipsContainer: UIView!
    private var chipsScrollView: UIScrollView!
    private var statusLabel: UILabel!
    private var spinner: UIActivityIndicatorView!

    // MARK: - 生命周期

    init() { super.init(style: .plain) }
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择照片目录"
        view.backgroundColor = UIColor(argb: 0xFF101216)
        tableView.backgroundColor = UIColor(argb: 0xFF101216)
        tableView.separatorColor = UIColor(white: 1.0, alpha: 0.08)
        tableView.rowHeight = 54

        selectedDirs = settings.getSelectedDirs()
        shareName = settings.getNasConfig()?.shareName ?? ""

        buildToolbar()
        buildHeader()

        if shareName.isEmpty {
            loadShares()
        } else {
            loadDirs(path: "/")
        }
    }

    // MARK: - 顶部工具条

    private func buildToolbar() {
        btnParent = UIBarButtonItem(
            title: "↑ 上一级", style: .plain,
            target: self, action: #selector(goParent)
        )
        btnAddCurrent = UIBarButtonItem(
            title: "＋ 选择当前目录", style: .plain,
            target: self, action: #selector(confirmCurrentDir)
        )
        btnConfirm = UIBarButtonItem(
            title: "保存", style: .done,
            target: self, action: #selector(saveAndExit)
        )
        navigationItem.rightBarButtonItems = [btnConfirm]
        navigationItem.leftBarButtonItem = btnParent
        toolbarItems = [btnAddCurrent]
        navigationController?.isToolbarHidden = false
    }

    private func buildHeader() {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 132))
        header.backgroundColor = UIColor(argb: 0xFF1B1F26)

        statusLabel = UILabel()
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = UIColor(argb: 0xFFE8B64C)
        statusLabel.numberOfLines = 1
        header.addSubview(statusLabel)

        spinner = UIActivityIndicatorView(activityIndicatorStyle: .white)
        spinner.hidesWhenStopped = true
        spinner.color = UIColor(argb: 0xFFE8B64C)
        header.addSubview(spinner)

        // 已选目录 chips（横向滚动，✗ 移除）
        chipsScrollView = UIScrollView()
        chipsScrollView.alwaysBounceVertical = false
        chipsScrollView.showsHorizontalScrollIndicator = false
        header.addSubview(chipsScrollView)
        chipsContainer = UIView()
        chipsScrollView.addSubview(chipsContainer)

        // 包含子目录开关
        let switchLabel = UILabel()
        switchLabel.text = "包含子目录"
        switchLabel.font = .systemFont(ofSize: 14)
        switchLabel.textColor = UIColor(white: 1.0, alpha: 0.7)
        header.addSubview(switchLabel)
        switchSubdir = UISwitch()
        switchSubdir.onTintColor = UIColor(argb: 0xFFE8B64C)
        switchSubdir.isOn = settings.includeSubdir
        switchSubdir.addTarget(self, action: #selector(toggleSubdir), for: .valueChanged)
        header.addSubview(switchSubdir)

        switchLabel.sizeToFit()
        header.frame = CGRect(
            x: 0, y: 0, width: view.bounds.width, height: 132 + (selectedDirs.isEmpty ? 0 : 44)
        )
        let w = header.bounds.width

        statusLabel.frame = CGRect(x: 16, y: 12, width: w - 60, height: 20)
        spinner.frame = CGRect(x: w - 40, y: 10, width: 24, height: 24)
        switchLabel.frame = CGRect(x: 16, y: 88, width: switchLabel.bounds.width + 4, height: 24)
        switchSubdir.frame = CGRect(x: w - 64, y: 84, width: 52, height: 31)
        chipsScrollView.frame = CGRect(x: 0, y: 40, width: w, height: 40)

        tableView.tableHeaderView = header
        layoutChips()
    }

    /** 动态渲染已选目录 chips */
    private func layoutChips() {
        chipsContainer.subviews.forEach { $0.removeFromSuperview() }
        let hasSelection = !selectedDirs.isEmpty
        chipsScrollView.isHidden = !hasSelection

        if !hasSelection {
            let header = tableView.tableHeaderView
            var frame = header?.frame ?? .zero
            frame.size.height = 132
            header?.frame = frame
            tableView.tableHeaderView = header
            return
        }

        var x: CGFloat = 12
        let sorted = selectedDirs.sorted()
        for path in sorted {
            let chip = buildChip(text: path) { [weak self] in
                guard let self = self else { return }
                self.selectedDirs.remove(path)
                self.layoutChips()
                self.tableView.reloadData()
            }
            chip.frame.origin = CGPoint(x: x, y: 4)
            chipsContainer.addSubview(chip)
            x += chip.bounds.width + 8
        }
        chipsContainer.frame = CGRect(x: 0, y: 0, width: max(x, chipsScrollView.bounds.width), height: 40)
        chipsScrollView.contentSize = CGSize(width: max(x, chipsScrollView.bounds.width), height: 40)

        let header = tableView.tableHeaderView
        var frame = header?.frame ?? .zero
        frame.size.height = 132 + 44
        header?.frame = frame
        tableView.tableHeaderView = header
    }

    private func buildChip(text: String, onRemove: @escaping () -> Void) -> UIView {
        let chip = UIView()
        chip.backgroundColor = UIColor(white: 1.0, alpha: 0.10)
        chip.layer.cornerRadius = 12

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 12)
        label.textColor = UIColor(white: 1.0, alpha: 0.8)
        label.sizeToFit()
        let labelW = min(label.bounds.width + 16, 220)
        label.frame = CGRect(x: 10, y: 9, width: labelW, height: 18)
        label.lineBreakMode = .byTruncatingMiddle
        chip.addSubview(label)

        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.setTitleColor(UIColor(white: 1.0, alpha: 0.55), for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 12, weight: .bold)
        close.frame = CGRect(x: labelW + 12, y: 7, width: 26, height: 26)
        close.addTarget(self, action: #selector(chipCloseTapped), for: .touchUpInside)
        close.accessibilityLabel = text
        chip.addSubview(close)
        chipCloseActions.append((close, onRemove))
        chip.frame = CGRect(x: 0, y: 0, width: labelW + 50, height: 36)
        return chip
    }

    /// chip 关闭按钮回调表（避免闭包持有问题，刷新时重建）
    private var chipCloseActions: [(UIButton, () -> Void)] = []

    @objc private func chipCloseTapped(_ sender: UIButton) {
        for (button, action) in chipCloseActions where button === sender {
            action()
            return
        }
    }

    // MARK: - 数据加载

    private func beginLoading(_ pathText: String) {
        isLoading = true
        errorMessage = nil
        items = []
        statusLabel.text = pathText
        spinner.startAnimating()
        tableView.reloadData()
    }

    private func endLoading(_ error: String?) {
        isLoading = false
        spinner.stopAnimating()
        if let e = error { errorMessage = e }
        tableView.reloadData()
    }

    /** 首屏：列出所有共享名 */
    private func loadShares() {
        beginLoading("共享列表")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.nasRepository.listShares()
            DispatchQueue.main.async {
                switch result {
                case .success(let shares):
                    var nodes: [NasDirNode] = []
                    for s in shares where !s.hasSuffix("$") { // 过滤系统管理共享
                        nodes.append(NasDirNode(
                            name: s, path: s, isDirectory: true
                        ))
                    }
                    nodes.sort { $0.name < $1.name }
                    self.items = nodes
                    self.endLoading(nil)
                case .failure(let error):
                    self.endLoading("加载失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /** 列出共享内指定路径的子目录 */
    private func loadDirs(path: String) {
        currentPath = path
        beginLoading("/\(shareName)\(path == "/" ? "" : path)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.nasRepository.listDirectories(shareName: self.shareName, path: path)
            DispatchQueue.main.async {
                switch result {
                case .success(let dirs):
                    self.items = dirs.sorted {
                        if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                        return $0.name < $1.name
                    }
                    self.endLoading(nil)
                case .failure(let error):
                    self.endLoading("加载失败：\(error.localizedDescription)")
                }
            }
        }
        updateToolbarState()
    }

    private func updateToolbarState() {
        btnParent.isEnabled = !shareName.isEmpty && currentPath != "/"
        btnAddCurrent.isEnabled = !shareName.isEmpty
    }

    // MARK: - 操作

    @objc private func goParent() {
        guard !shareName.isEmpty, currentPath != "/" else { return }
        let parent = NasDirNode(name: "", path: currentPath, isDirectory: true).parentPath
        loadDirs(path: parent)
    }

    @objc private func confirmCurrentDir() {
        guard !shareName.isEmpty else { return }
        // 存储为 "/共享名/子路径"，扫描时解析回共享+内路径
        let inner = currentPath == "/" ? "" : currentPath
        let fullPath = "/\(shareName)\(inner)"
        selectedDirs.insert(fullPath)
        layoutChips()
        tableView.reloadData()
    }

    @objc private func saveAndExit() {
        settings.setSelectedDirs(selectedDirs)
        navigationController?.popViewController(animated: true)
    }

    @objc private func toggleSubdir() {
        settings.includeSubdir = switchSubdir.isOn
    }

    /// 长按目录项 → 切换选中
    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let point = g.location(in: tableView)
        guard let indexPath = tableView.indexPathForRow(at: point) else { return }
        let node = items[indexPath.row]
        guard node.isDirectory else { return }
        let fullPath = shareName.isEmpty ? node.path : "/\(shareName)\(node.path == "/" ? "" : node.path)"
        if selectedDirs.contains(fullPath) {
            selectedDirs.remove(fullPath)
        } else {
            selectedDirs.insert(fullPath)
        }
        layoutChips()
        tableView.reloadData()
    }

    // MARK: - UITableViewDataSource / Delegate

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isLoading || errorMessage != nil { return 1 }
        return max(items.count, 1) // 空态占一行
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        // value1 样式带 detailTextLabel，需手工创建（不注册，避免得到默认样式）
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "cell")
        cell.backgroundColor = UIColor(argb: 0xFF161A20)
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = .systemFont(ofSize: 16)
        cell.detailTextLabel?.textColor = UIColor(argb: 0xFF8BC34A)
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.imageView?.image = nil

        if let error = errorMessage {
            cell.textLabel?.text = error
            cell.textLabel?.textColor = UIColor(argb: 0xFFFF8A65)
            cell.textLabel?.numberOfLines = 0
            cell.textLabel?.font = .systemFont(ofSize: 14)
            return cell
        }
        if isLoading {
            cell.textLabel?.text = "正在加载…"
            cell.textLabel?.textColor = UIColor(white: 1.0, alpha: 0.4)
            return cell
        }
        if items.isEmpty {
            cell.textLabel?.text = "此目录下没有子目录"
            cell.textLabel?.textColor = UIColor(white: 1.0, alpha: 0.4)
            return cell
        }

        let node = items[indexPath.row]
        cell.textLabel?.text = node.isDirectory ? "📁 \(node.name)" : node.name
        let fullPath = shareName.isEmpty
            ? node.path
            : "/\(shareName)\(node.path == "/" ? "" : node.path)"
        if node.isDirectory, selectedDirs.contains(fullPath) {
            cell.detailTextLabel?.text = "已选"
            cell.accessoryType = .checkmark
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard !isLoading, errorMessage == nil, indexPath.row < items.count else { return }
        let node = items[indexPath.row]

        if shareName.isEmpty {
            // 共享选择屏：进入该共享根目录（同时记住共享名，不立即持久化，保存时随目录写入路径）
            shareName = node.name
            loadDirs(path: "/")
            return
        }
        guard node.isDirectory else { return }
        loadDirs(path: node.path)
    }

    // MARK: - 长按手势

    lazy var longPressGesture: UILongPressGestureRecognizer = {
        return UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if longPressGesture.view == nil {
            tableView.addGestureRecognizer(longPressGesture)
        }
    }
}
