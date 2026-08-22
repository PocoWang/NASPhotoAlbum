import Foundation

/**
 * 夜间休眠调度类型（对应 Android 端 NightScheduleType）。
 */
enum NightScheduleType: Int, CaseIterable {
    /// 每天同一展示时段
    case unified = 0
    /// 工作日与休息日（周末+法定节假日）分别设定
    case workRest = 1
    /// 周一到周日每天单独设定
    case perDay = 2

    var display: String {
        switch self {
        case .unified: return "每天相同时段"
        case .workRest: return "工作日 / 休息日"
        case .perDay: return "每天单独设置"
        }
    }

    static func fromValue(_ v: Int) -> NightScheduleType {
        return NightScheduleType(rawValue: v) ?? .unified
    }
}

/**
 * 夜间休眠时间表（对应 Android 端 NightSchedule，逻辑一比一移植）。
 *
 * 时段语义：[start, end) 为展示时段，支持跨午夜（start > end 表示当日晚段延续到次日早段）；
 * start == end 视为全天展示。
 *
 * 三种调度类型：
 * - .unified：每天同一时段
 * - .workRest：工作日 / 休息日（周末+法定节假日，调休上班日按工作日）分别设定
 * - .perDay：周一~周日逐日设定
 */
enum NightSchedule {

    /// 一天的展示时段（分钟数，0 = 00:00）
    struct DayRange {
        var start: Int
        var end: Int
    }

    /// 当前时刻（一天内分钟数）
    static func nowMinuteOfDay() -> Int {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
    }

    /// 今天偏移 dayOffset 天的展示时段（按调度类型 + 节假日/星期判定）
    static func rangeForDay(_ store: SettingsStore, dayOffset: Int) -> DayRange {
        switch store.getNightScheduleType() {
        case .unified:
            return DayRange(
                start: store.getNightModeStartMinute(),
                end: store.getNightModeEndMinute()
            )
        case .workRest:
            if HolidayCalendar.isRestDayOffset(dayOffset) {
                return DayRange(
                    start: store.getNightRestdayStartMinute(),
                    end: store.getNightRestdayEndMinute()
                )
            } else {
                return DayRange(
                    start: store.getNightWorkdayStartMinute(),
                    end: store.getNightWorkdayEndMinute()
                )
            }
        case .perDay:
            let isoDay = isoDayOfWeek(dayOffset) // 1=周一 … 7=周日
            return DayRange(
                start: store.getNightDayStart(isoDay),
                end: store.getNightDayEnd(isoDay)
            )
        }
    }

    /// 当前是否处于展示时段
    static func isShowTimeNow(_ store: SettingsStore) -> Bool {
        return isShowAt(nowMinuteOfDay()) { rangeForDay(store, dayOffset: $0) }
    }

    /**
     * 距下一次展示状态切换（进入休眠 / 恢复展示）的毫秒数。
     * 逐日扫描边界（未来最多 9 天），正确处理跨午夜与每天不同时段。
     */
    static func msUntilNextStateChange(_ store: SettingsStore) -> Int64 {
        let now = nowMinuteOfDay()
        let rf: (Int) -> DayRange = { rangeForDay(store, dayOffset: $0) }
        if let boundary = scanBoundaries(rf, predicate: { b in
            b > now && isShowAt(b - 1, rf: rf) != isShowAt(b, rf: rf)
        }) {
            return Int64((boundary - now) * 60_000)
        }
        // 全部为全天展示：状态永不变化，返回较大值（调用方仍会以 30s 心跳兜底）
        return Int64(24 * 3600_000)
    }

    /**
     * 下一次开始展示的时刻描述：
     * 今天恢复 → "07:00"；未来某天 → "周三 07:00"。
     */
    static func nextShowStartText(_ store: SettingsStore) -> String {
        let now = nowMinuteOfDay()
        let rf: (Int) -> DayRange = { rangeForDay(store, dayOffset: $0) }
        guard let b = scanBoundaries(rf, predicate: { b in
            b > now && !isShowAt(b - 1, rf: rf) && isShowAt(b, rf: rf)
        }) else {
            return formatMinute(rf(0).start)
        }
        if b / 1440 == 0 {
            return formatMinute(b % 1440)
        }
        return "\(weekDayName(b / 1440)) \(formatMinute(b % 1440))"
    }

    /// 在未来 9 天的展示状态边界中找到第一个满足 predicate 的绝对分钟时刻
    private static func scanBoundaries(
        _ rf: (Int) -> DayRange,
        predicate: (Int) -> Bool
    ) -> Int? {
        for day in 0...9 {
            for b in boundariesForDay(day, rf: rf) {
                if predicate(b) { return b }
            }
        }
        return nil
    }

    /**
     * day 当天可能发生展示状态切换的绝对分钟时刻。
     * 注意跨午夜时段（start > end）的结束边界在次日早晨。
     */
    private static func boundariesForDay(_ day: Int, rf: (Int) -> DayRange) -> [Int] {
        let r = rf(day)
        if r.start == r.end { return [] } // 全天展示，无边界
        if r.start < r.end {
            return [day * 1440 + r.start, day * 1440 + r.end]
        }
        return [day * 1440 + r.start, (day + 1) * 1440 + r.end]
    }

    /// 绝对分钟（day*1440 + 分钟）时刻是否展示。跨午夜时段由前一天的延续覆盖次日早段。
    private static func isShowAt(_ absMinute: Int, rf: (Int) -> DayRange) -> Bool {
        let day = absMinute / 1440
        let m = absMinute % 1440
        let r = rf(day)
        if r.start == r.end { return true }
        if r.start < r.end {
            return m >= r.start && m < r.end
        }
        // 跨午夜：当日晚段 + 前一天时段延续到今晨
        if m >= r.start { return true }
        let prev = rf(day - 1)
        return prev.start > prev.end && m < prev.end
    }

    /// 今天偏移 dayOffset 天的 ISO 星期（1=周一 … 7=周日）
    private static func isoDayOfWeek(_ dayOffset: Int) -> Int {
        guard let date = Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) else {
            return 1
        }
        let wd = Calendar.current.component(.weekday, from: date) // 1=周日 … 7=周六
        return wd == 1 ? 7 : wd - 1
    }

    /// 未来第 offset 天的中文星期名（1=明天）
    private static func weekDayName(_ offset: Int) -> String {
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else {
            return ""
        }
        let wd = Calendar.current.component(.weekday, from: date)
        let names: [Int: String] = [
            2: "周一", 3: "周二", 4: "周三", 5: "周四", 6: "周五", 7: "周六", 1: "周日"
        ]
        return names[wd] ?? ""
    }

    /// 分钟数格式化为 HH:mm
    static func formatMinute(_ minute: Int) -> String {
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
