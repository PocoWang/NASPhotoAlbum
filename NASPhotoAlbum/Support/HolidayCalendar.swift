import Foundation

/**
 * 中国法定节假日日历（用于夜间休眠的"工作日 / 休息日"判定）。
 * （对应 Android 端 HolidayCalendar，数据一比一内置 2025、2026 两年。）
 *
 * 数据来源：国务院办公厅年度放假通知。
 * 每年 11 月左右国务院发布次年安排后，在 holidays / makeupWorkdays 中追加即可。
 *
 * 判定优先级：
 * 1. 调休上班日（如春节前后的周六补班）→ 工作日
 * 2. 法定节假日 → 休息日
 * 3. 无数据的日期 → 按周六/周日为休息日
 */
enum HolidayCalendar {

    /// 法定节假日（含调休连休，格式 yyyy-MM-dd）
    private static let holidays: Set<String> = {
        var set = Set<String>()
        // ===== 2025 =====
        // 元旦
        set.formUnion(dateRange(2025, 1, 1, 2025, 1, 1))
        // 春节：1/28 ~ 2/4
        set.formUnion(dateRange(2025, 1, 28, 2025, 2, 4))
        // 清明节：4/4 ~ 4/6
        set.formUnion(dateRange(2025, 4, 4, 2025, 4, 6))
        // 劳动节：5/1 ~ 5/5
        set.formUnion(dateRange(2025, 5, 1, 2025, 5, 5))
        // 端午节：5/31 ~ 6/2
        set.formUnion(dateRange(2025, 5, 31, 2025, 6, 2))
        // 国庆节、中秋节：10/1 ~ 10/8
        set.formUnion(dateRange(2025, 10, 1, 2025, 10, 8))

        // ===== 2026 =====
        // 元旦：1/1 ~ 1/3
        set.formUnion(dateRange(2026, 1, 1, 2026, 1, 3))
        // 春节：2/15 ~ 2/23
        set.formUnion(dateRange(2026, 2, 15, 2026, 2, 23))
        // 清明节：4/4 ~ 4/6
        set.formUnion(dateRange(2026, 4, 4, 2026, 4, 6))
        // 劳动节：5/1 ~ 5/5
        set.formUnion(dateRange(2026, 5, 1, 2026, 5, 5))
        // 端午节：6/19 ~ 6/21
        set.formUnion(dateRange(2026, 6, 19, 2026, 6, 21))
        // 中秋节：9/25 ~ 9/27
        set.formUnion(dateRange(2026, 9, 25, 2026, 9, 27))
        // 国庆节：10/1 ~ 10/7
        set.formUnion(dateRange(2026, 10, 1, 2026, 10, 7))
        return set
    }()

    /// 调休上班的周末（格式 yyyy-MM-dd）
    private static let makeupWorkdays: Set<String> = [
        // 2025
        "2025-01-26", "2025-02-08", "2025-04-27", "2025-09-28", "2025-10-11",
        // 2026
        "2026-02-14", "2026-02-28", "2026-05-09", "2026-10-10"
    ]

    /// 指定日期是否为休息日（法定节假日或普通周末，调休上班日除外）
    static func isRestDay(_ date: Date) -> Bool {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let y = comps.year, let m = comps.month, let d = comps.day, let wd = comps.weekday else {
            return false
        }
        let key = String(format: "%04d-%02d-%02d", y, m, d)
        if makeupWorkdays.contains(key) { return false }
        if holidays.contains(key) { return true }
        // iOS Calendar：weekday 1 = 周日，7 = 周六
        return wd == 1 || wd == 7
    }

    /// 今天偏移 dayOffset 天是否为休息日
    static func isRestDayOffset(_ dayOffset: Int) -> Bool {
        let date = Calendar.current.date(
            byAdding: .day, value: dayOffset, to: Date()
        ) ?? Date()
        return isRestDay(date)
    }

    /// 生成闭区间日期串（起止同天也支持）
    private static func dateRange(
        _ y1: Int, _ m1: Int, _ d1: Int,
        _ y2: Int, _ m2: Int, _ d2: Int
    ) -> [String] {
        var out: [String] = []
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = y1; comps.month = m1; comps.day = d1
        comps.hour = 12 // 避免夏令时边界问题
        guard var cursor = cal.date(from: comps) else { return out }
        comps.year = y2; comps.month = m2; comps.day = d2
        comps.hour = 12
        guard let end = cal.date(from: comps) else { return out }
        while cursor <= end {
            let c = cal.dateComponents([.year, .month, .day], from: cursor)
            if let y = c.year, let m = c.month, let d = c.day {
                out.append(String(format: "%04d-%02d-%02d", y, m, d))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return out
    }
}
