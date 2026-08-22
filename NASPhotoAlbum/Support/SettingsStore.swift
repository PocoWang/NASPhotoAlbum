import Foundation

/**
 * 偏好存储（与 Android 端 SettingsStore 一比一对应，键名完全相同）。
 *
 * 存储约定（沿用 Android 端）：
 * - 字符串字段：直接 String
 * - 数值/枚举值/时间戳：统一用 String 存储，getter 内部做类型转换
 * - 布尔字段：Bool
 * - 字符串集合（selectedDirs）：[String]
 *
 * 安全性：UserDefaults 存于应用沙盒，仅本应用可访问。
 */
final class SettingsStore {

    private let defaults = UserDefaults.standard

    // MARK: - 键定义（与 Android preferences.xml 完全一致）

    static let keyNasHost = "nas_host"
    static let keyNasPort = "nas_port"
    static let keyNasUsername = "nas_username"
    static let keyNasPassword = "nas_password"
    static let keyNasDomain = "nas_domain"
    static let keyShareName = "share_name"
    static let keySelectedDirs = "selected_dirs"
    static let keyIncludeSubdir = "include_subdir"
    static let keyCacheSize = "cache_size_bytes"
    static let keyScanPeriod = "scan_period"
    static let keyLastScanTime = "last_scan_time"
    static let keyPlayOrder = "play_order"
    static let keyPlayInterval = "play_interval_ms"
    static let keyTransition = "transition_type"
    static let keyClockStyle = "clock_style"
    static let keyDisplayMode = "display_mode"
    static let keyClockFont = "clock_font"
    static let keyClockSizeSp = "clock_size_sp"
    static let keyClockColor = "clock_color"
    static let keyClockShadow = "clock_shadow"
    static let keyClockStrokeEnabled = "clock_stroke_enabled"
    static let keyClockStrokeColor = "clock_stroke_color"
    static let keyClockPositionRatio = "clock_position_ratio"
    static let keyNightModeEnabled = "night_mode_enabled"
    static let keyNightModeStart = "night_mode_start"
    static let keyNightModeEnd = "night_mode_end"
    static let keyNightModeType = "night_mode_type"
    static let keyNightWorkdayStart = "night_workday_start"
    static let keyNightWorkdayEnd = "night_workday_end"
    static let keyNightRestdayStart = "night_restday_start"
    static let keyNightRestdayEnd = "night_restday_end"
    static let keyNightDayStartPrefix = "night_day_start_"
    static let keyNightDayEndPrefix = "night_day_end_"

    // MARK: - 默认值

    /// 夜间休眠默认展示时段：07:00 ~ 23:00
    static let defaultNightStartMinute = 7 * 60
    static let defaultNightEndMinute = 23 * 60
    /// 工作日默认时段：07:00 ~ 23:00；休息日默认时段：08:00 ~ 23:30
    static let defaultWorkdayStart = 7 * 60
    static let defaultWorkdayEnd = 23 * 60
    static let defaultRestdayStart = 8 * 60
    static let defaultRestdayEnd = 23 * 60 + 30
    /// 时钟默认字号（pt）
    static let defaultClockSizeSp = 48

    /// 时钟可选颜色（与 Android arrays.xml 顺序一致）
    static let clockColors: [Int] = [
        0xFFFFFFFF, // 白
        0xFFFFD54F, // 暖黄
        0xFF90CAF9, // 浅蓝
        0xFFA5D6A7, // 薄荷绿
        0xFFF8BBD0  // 柔粉
    ]

    /// 描边可选颜色
    static let strokeColors: [Int] = [
        0xFF000000, // 黑
        0xFFFFFFFF, // 白
        0xFF424242  // 深灰
    ]

    static func clockColor(of index: Int) -> Int {
        let i = max(0, min(index, clockColors.count - 1))
        return clockColors[i]
    }

    static func strokeColor(of index: Int) -> Int {
        let i = max(0, min(index, strokeColors.count - 1))
        return strokeColors[i]
    }

    // MARK: - NAS 连接配置

    func getNasConfig() -> SmbConfig? {
        let host = defaults.string(forKey: SettingsStore.keyNasHost) ?? ""
        let username = defaults.string(forKey: SettingsStore.keyNasUsername) ?? ""
        if host.isEmpty || username.isEmpty { return nil }
        let port = Int(defaults.string(forKey: SettingsStore.keyNasPort) ?? "")
            ?? AppConstants.smbDefaultPort
        return SmbConfig(
            host: host,
            port: port,
            username: username,
            password: defaults.string(forKey: SettingsStore.keyNasPassword) ?? "",
            domain: defaults.string(forKey: SettingsStore.keyNasDomain) ?? "",
            shareName: defaults.string(forKey: SettingsStore.keyShareName) ?? ""
        )
    }

    func saveNasConfig(_ config: SmbConfig) {
        defaults.set(config.host, forKey: SettingsStore.keyNasHost)
        defaults.set(String(config.port), forKey: SettingsStore.keyNasPort)
        defaults.set(config.username, forKey: SettingsStore.keyNasUsername)
        defaults.set(config.password, forKey: SettingsStore.keyNasPassword)
        defaults.set(config.domain, forKey: SettingsStore.keyNasDomain)
        defaults.set(config.shareName, forKey: SettingsStore.keyShareName)
    }

    var isConfigured: Bool { getNasConfig() != nil }

    // MARK: - 照片目录

    func getSelectedDirs() -> Set<String> {
        return Set(defaults.stringArray(forKey: SettingsStore.keySelectedDirs) ?? [])
    }

    func setSelectedDirs(_ dirs: Set<String>) {
        defaults.set(Array(dirs), forKey: SettingsStore.keySelectedDirs)
    }

    var includeSubdir: Bool {
        get { defaults.object(forKey: SettingsStore.keyIncludeSubdir) as? Bool ?? true }
        set { defaults.set(newValue, forKey: SettingsStore.keyIncludeSubdir) }
    }

    // MARK: - 缓存设置

    func getCacheSizeBytes() -> Int64 {
        if let s = defaults.string(forKey: SettingsStore.keyCacheSize), let v = Int64(s) { return v }
        return AppConstants.defaultCacheSizeBytes
    }

    func setCacheSizeBytes(_ bytes: Int64) {
        defaults.set(String(bytes), forKey: SettingsStore.keyCacheSize)
    }

    // MARK: - 扫描设置

    func getScanPeriod() -> ScanPeriod {
        let v = Int(defaults.string(forKey: SettingsStore.keyScanPeriod) ?? "") ?? 1
        return ScanPeriod.fromValue(v)
    }

    func setScanPeriod(_ period: ScanPeriod) {
        defaults.set(String(period.rawValue), forKey: SettingsStore.keyScanPeriod)
    }

    func getLastScanTime() -> Int64 {
        if let s = defaults.string(forKey: SettingsStore.keyLastScanTime), let v = Int64(s) { return v }
        return 0
    }

    func setLastScanTime(_ timestamp: Int64) {
        defaults.set(String(timestamp), forKey: SettingsStore.keyLastScanTime)
    }

    // MARK: - 播放设置

    func getPlayOrder() -> PlayOrder {
        return PlayOrder.fromValue(Int(defaults.string(forKey: SettingsStore.keyPlayOrder) ?? "") ?? 0)
    }

    func setPlayOrder(_ order: PlayOrder) {
        defaults.set(String(order.rawValue), forKey: SettingsStore.keyPlayOrder)
    }

    func getPlayIntervalMs() -> Int64 {
        if let s = defaults.string(forKey: SettingsStore.keyPlayInterval), let v = Int64(s) { return v }
        return AppConstants.defaultPlayIntervalMs
    }

    func setPlayIntervalMs(_ ms: Int64) {
        defaults.set(String(ms), forKey: SettingsStore.keyPlayInterval)
    }

    func getTransitionType() -> TransitionType {
        return TransitionType.fromValue(Int(defaults.string(forKey: SettingsStore.keyTransition) ?? "") ?? 0)
    }

    func setTransitionType(_ type: TransitionType) {
        defaults.set(String(type.rawValue), forKey: SettingsStore.keyTransition)
    }

    func getClockStyle() -> ClockStyle {
        return ClockStyle.fromValue(Int(defaults.string(forKey: SettingsStore.keyClockStyle) ?? "") ?? 0)
    }

    func setClockStyle(_ style: ClockStyle) {
        defaults.set(String(style.rawValue), forKey: SettingsStore.keyClockStyle)
    }

    func getDisplayMode() -> DisplayMode {
        return DisplayMode.fromValue(Int(defaults.string(forKey: SettingsStore.keyDisplayMode) ?? "") ?? 0)
    }

    func setDisplayMode(_ mode: DisplayMode) {
        defaults.set(String(mode.rawValue), forKey: SettingsStore.keyDisplayMode)
    }

    /// 取实际生效的展示模式。用户选了 RANDOM 时每次调用随机返回一个具体模式。
    func getEffectiveDisplayMode() -> DisplayMode {
        let saved = getDisplayMode()
        if saved == .random {
            return DisplayMode.concreteModes.randomElement() ?? .single
        }
        return saved
    }

    // MARK: - 时钟外观

    func getClockFont() -> ClockFont {
        return ClockFont.fromValue(Int(defaults.string(forKey: SettingsStore.keyClockFont) ?? "") ?? 0)
    }

    func setClockFont(_ font: ClockFont) {
        defaults.set(String(font.rawValue), forKey: SettingsStore.keyClockFont)
    }

    func getClockSizeSp() -> Int {
        return Int(defaults.string(forKey: SettingsStore.keyClockSizeSp) ?? "") ?? SettingsStore.defaultClockSizeSp
    }

    func setClockSizeSp(_ sizeSp: Int) {
        defaults.set(String(sizeSp), forKey: SettingsStore.keyClockSizeSp)
    }

    /// 时钟文字颜色（ARGB），默认白色
    func getClockColor() -> Int {
        let idx = Int(defaults.string(forKey: SettingsStore.keyClockColor) ?? "") ?? 0
        return SettingsStore.clockColor(of: idx)
    }

    func setClockColorIndex(_ index: Int) {
        defaults.set(String(index), forKey: SettingsStore.keyClockColor)
    }

    func getClockShadow() -> ClockShadow {
        return ClockShadow.fromValue(Int(defaults.string(forKey: SettingsStore.keyClockShadow) ?? "") ?? 1)
    }

    func setClockShadow(_ shadow: ClockShadow) {
        defaults.set(String(shadow.rawValue), forKey: SettingsStore.keyClockShadow)
    }

    var clockStrokeEnabled: Bool {
        get { defaults.bool(forKey: SettingsStore.keyClockStrokeEnabled) }
        set { defaults.set(newValue, forKey: SettingsStore.keyClockStrokeEnabled) }
    }

    /// 描边颜色（ARGB），默认黑色
    func getClockStrokeColor() -> Int {
        let idx = Int(defaults.string(forKey: SettingsStore.keyClockStrokeColor) ?? "") ?? 0
        return SettingsStore.strokeColor(of: idx)
    }

    func setClockStrokeColorIndex(_ index: Int) {
        defaults.set(String(index), forKey: SettingsStore.keyClockStrokeColor)
    }

    /// 时钟位置（绝对坐标比例），存储 "xRatio,yRatio"，代表时钟中心点在容器中的相对位置。
    func getClockPositionRatio() -> (Float, Float) {
        if let raw = defaults.string(forKey: SettingsStore.keyClockPositionRatio) {
            let parts = raw.split(separator: ",").map { Float($0) }
            if parts.count == 2, let x = parts[0], let y = parts[1] {
                return (min(max(x, 0), 1), min(max(y, 0), 1))
            }
        }
        return (0.90, 0.10) // 默认右上角
    }

    func setClockPositionRatio(x xRatio: Float, y yRatio: Float) {
        let x = min(max(xRatio, 0), 1)
        let y = min(max(yRatio, 0), 1)
        defaults.set("\(x),\(y)", forKey: SettingsStore.keyClockPositionRatio)
    }

    // MARK: - 夜间休眠

    var nightModeEnabled: Bool {
        get { defaults.bool(forKey: SettingsStore.keyNightModeEnabled) }
        set { defaults.set(newValue, forKey: SettingsStore.keyNightModeEnabled) }
    }

    /// 展示开始时刻（一天内分钟数，默认 07:00）
    func getNightModeStartMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightModeStart), let v = Int(s) { return v }
        return SettingsStore.defaultNightStartMinute
    }

    func setNightModeStartMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightModeStart)
    }

    /// 展示结束时刻（一天内分钟数，默认 23:00）
    func getNightModeEndMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightModeEnd), let v = Int(s) { return v }
        return SettingsStore.defaultNightEndMinute
    }

    func setNightModeEndMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightModeEnd)
    }

    /// 调度类型（统一时段 / 工作日休息日 / 每天单独）
    func getNightScheduleType() -> NightScheduleType {
        return NightScheduleType.fromValue(Int(defaults.string(forKey: SettingsStore.keyNightModeType) ?? "") ?? 0)
    }

    func setNightScheduleType(_ type: NightScheduleType) {
        defaults.set(String(type.rawValue), forKey: SettingsStore.keyNightModeType)
    }

    /// 工作日展示时段（默认 07:00 ~ 23:00）
    func getNightWorkdayStartMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightWorkdayStart), let v = Int(s) { return v }
        return SettingsStore.defaultWorkdayStart
    }

    func setNightWorkdayStartMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightWorkdayStart)
    }

    func getNightWorkdayEndMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightWorkdayEnd), let v = Int(s) { return v }
        return SettingsStore.defaultWorkdayEnd
    }

    func setNightWorkdayEndMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightWorkdayEnd)
    }

    /// 休息日展示时段（周末+法定节假日，默认 08:00 ~ 23:30）
    func getNightRestdayStartMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightRestdayStart), let v = Int(s) { return v }
        return SettingsStore.defaultRestdayStart
    }

    func setNightRestdayStartMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightRestdayStart)
    }

    func getNightRestdayEndMinute() -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightRestdayEnd), let v = Int(s) { return v }
        return SettingsStore.defaultRestdayEnd
    }

    func setNightRestdayEndMinute(_ minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightRestdayEnd)
    }

    /// 逐日展示时段。day 为 ISO 星期（1=周一 … 7=周日）。
    /// 默认：周一~周五 07:00~23:00，周六周日 08:00~23:30。
    func getNightDayStart(_ day: Int) -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightDayStartPrefix + String(day)), let v = Int(s) { return v }
        return day <= 5 ? SettingsStore.defaultWorkdayStart : SettingsStore.defaultRestdayStart
    }

    func setNightDayStart(_ day: Int, minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightDayStartPrefix + String(day))
    }

    func getNightDayEnd(_ day: Int) -> Int {
        if let s = defaults.string(forKey: SettingsStore.keyNightDayEndPrefix + String(day)), let v = Int(s) { return v }
        return day <= 5 ? SettingsStore.defaultWorkdayEnd : SettingsStore.defaultRestdayEnd
    }

    func setNightDayEnd(_ day: Int, minute: Int) {
        defaults.set(String(minute), forKey: SettingsStore.keyNightDayEndPrefix + String(day))
    }
}
