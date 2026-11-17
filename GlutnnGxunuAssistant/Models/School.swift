import Foundation

// MARK: - 学校配置

/// 学校 id。登录页选择器直接读 schools 表。
enum SchoolID: String, CaseIterable {
    case gut = "gut"
    case gxvnu = "gxvnu"
}

/// 每所学校的教务配置。默认桂工。
struct SchoolConfig: Equatable {
    let id: SchoolID
    /// App 内显示名。
    let displayName: String
    /// 教务域名，如 jw.glutnn.cn / jw.gxvnu.edu.cn。
    let host: String
    /// 是否用 HTTPS（桂工纯 HTTP，职师院 HTTPS）。
    let useHttps: Bool
    /// 接口路径前缀：桂工 ""，正方 V9.0 "/jwglxt"。
    let pathPrefix: String
    /// 正方 V9.0 功能模块代码（gnmkdm）。桂工不用。
    let gnmkdm: [String: String]
    /// 登录默认是否需要验证码（桂工每次都要，职师院默认不要）。
    let captchaRequired: Bool
    /// 本学期第一周的周一（用于算当前周）。
    let termStartDate: Date
    /// 每节课开始时间 [时, 分]，共 11 条。
    let startTimeList: [(Int, Int)]
    /// 每节课结束时间 [时, 分]，共 11 条。
    let endTimeList: [(Int, Int)]

    var sectionCount: Int { startTimeList.count }

    static func == (lhs: SchoolConfig, rhs: SchoolConfig) -> Bool {
        lhs.id == rhs.id
    }

    /// 按本校 scheme/host/prefix 拼接口地址。
    func url(_ path: String, query: [String: String]? = nil) -> URL? {
        let fullPath = pathPrefix + path
        var components = URLComponents()
        components.scheme = useHttps ? "https" : "http"
        components.host = host
        components.path = fullPath
        if let query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }
}

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = DateComponents()
    c.year = y; c.month = m; c.day = d
    return Calendar(identifier: .gregorian).date(from: c) ?? Date()
}

/// 桂林理工大学（老正方）。作息与 Flutter 版一致。
let gutSchool = SchoolConfig(
    id: .gut,
    displayName: "桂林理工大学",
    host: "jw.glutnn.cn",
    useHttps: false,
    pathPrefix: "",
    gnmkdm: [:],
    captchaRequired: true,
    termStartDate: date(2026, 9, 7),
    startTimeList: [(8, 40), (9, 25), (10, 25), (11, 10), (14, 30), (15, 15), (16, 5), (16, 50), (19, 30), (20, 15), (21, 0)],
    endTimeList: [(9, 20), (10, 5), (11, 5), (11, 50), (15, 10), (15, 55), (16, 45), (17, 30), (20, 10), (20, 55), (21, 40)]
)

/// 广西职业师范学院（正方 V9.0 jwglxt）。
/// 作息：上午 1-5 节 8:00-12:00，下午 6-9 节 14:30-17:40，晚上 10-11 节 19:30-21:00。
/// 学期 2026-2027-1（2026-08-31 至 2027-01-10）。
let gxvnuSchool = SchoolConfig(
    id: .gxvnu,
    displayName: "广西职业师范学院",
    host: "jw.gxvnu.edu.cn",
    useHttps: true,
    pathPrefix: "/jwglxt",
    gnmkdm: ["课表": "N2151", "成绩": "N305005", "考试": "N358105"],
    captchaRequired: false,
    termStartDate: date(2026, 8, 31),
    startTimeList: [(8, 0), (8, 50), (9, 40), (10, 30), (11, 20), (14, 30), (15, 20), (16, 10), (17, 0), (19, 30), (20, 20)],
    endTimeList: [(8, 40), (9, 30), (10, 20), (11, 10), (12, 0), (15, 10), (16, 0), (16, 50), (17, 40), (20, 10), (21, 0)]
)

/// 目前就这两所学校。
let schools: [SchoolConfig] = [gutSchool, gxvnuSchool]

func schoolById(_ id: SchoolID) -> SchoolConfig {
    schools.first(where: { $0.id == id }) ?? gutSchool
}

// MARK: - 课程模型（两校共用）

/// 一门课的一次上课（某星期某节次）。同一门课在不同周/节次会展开成多条。
struct Course: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let teacher: String
    let location: String
    /// 星期：1=星期一 … 7=星期日。
    let weekday: Int
    /// 开始节次（1 起）。
    let startSection: Int
    /// 结束节次（含）。
    let endSection: Int
    /// 上课周次，如 [1, 2, 3]。
    let weeks: [Int]
    /// 备注（如教学班名、调课信息）。
    let extra: String

    init(name: String, teacher: String, location: String, weekday: Int, startSection: Int, endSection: Int, weeks: [Int], extra: String = "") {
        self.name = name
        self.teacher = teacher
        self.location = location
        self.weekday = weekday
        self.startSection = startSection
        self.endSection = endSection
        self.weeks = weeks
        self.extra = extra
    }
}

let weekdayNames = ["", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]

func weekdayNumber(from text: String) -> Int? {
    weekdayNames.firstIndex(of: text)
}

// MARK: - 周次区间解析（从 Flutter 版 parseWeekList 原样移植）

/// 输入如 "11-14"、"11-14,15-17"、"11-14单"、"11-14双,15-17单"、"11"。
/// 返回 (weeks, special)：special 为 true 表示含单/双或逗号，调用方按逐周赋值；
/// false 表示普通区间/单周。
func parseWeekList(_ weekInterval: String) -> (weeks: [Int], special: Bool) {
    var weekList: [Int] = []
    var specialWeek = true

    func step3BySection(_ section: String) {
        let range = section.split(separator: "-")
        if range.count == 2, let a = Int(range[0]), let b = Int(range[1]) {
            for i in a...b { weekList.append(i) }
        } else if range.count == 1, let a = Int(range[0]) {
            weekList.append(a)
        }
    }

    func step3() {
        for section in weekInterval.split(separator: ",") {
            step3BySection(String(section))
        }
    }

    func handleSingleOrDouble(_ section: String, isEven: Bool) {
        let key = isEven ? "双" : "单"
        let cleaned = section.replacingOccurrences(of: key, with: "")
        let range = cleaned.split(separator: "-")
        if range.count == 2, let a = Int(range[0]), let b = Int(range[1]) {
            for i in a...b where (isEven ? i.isMultiple(of: 2) : !i.isMultiple(of: 2)) {
                weekList.append(i)
            }
        } else if range.count == 1, let week = Int(range[0]) {
            if week.isMultiple(of: 2) == isEven { weekList.append(week) }
        }
    }

    func step4() {
        weekList = []
        for section in weekInterval.split(separator: ",") {
            let s = String(section)
            if s.contains("单") {
                handleSingleOrDouble(s, isEven: false)
            } else if s.contains("双") {
                handleSingleOrDouble(s, isEven: true)
            } else {
                step3BySection(s)
            }
        }
    }

    if weekInterval.contains("单") || weekInterval.contains("双") {
        step4()
    } else if weekInterval.contains(",") {
        step3()
    } else {
        specialWeek = false
        weekList = weekInterval.split(separator: "-").map { Int($0) ?? 0 }
    }
    return (weekList, specialWeek)
}

/// 按 Flutter 版 getSchedule 的展开规则，把解析结果变成周次列表。
/// - simple 区间 "11-14"（special=false, weeks=[11,14]）→ 11...14
/// - 单周 "11" → [11]
/// - 含单/双或逗号（special=true）→ 按展开后的逐周列表
func expandWeeks(_ parsed: (weeks: [Int], special: Bool), rawInterval: String) -> [Int] {
    let (weekList, special) = parsed
    if (weekList.count > 1 && special) || weekList.count >= 3 {
        return weekList
    } else if weekList.count == 2 {
        let a = weekList[0], b = weekList[1]
        guard a <= b else { return [] }
        return Array(a...b)
    } else if weekList.count == 1 {
        return [weekList[0]]
    } else {
        return []
    }
}

// MARK: - 当前周

/// 从学期开始日往后数，当前是第几周（1 起，超 20 周按 20 算）。
func currentWeek(for school: SchoolConfig, on date: Date = Date()) -> Int {
    let cal = Calendar(identifier: .gregorian)
    let start = cal.startOfDay(for: school.termStartDate)
    let today = cal.startOfDay(for: date)
    let days = cal.dateComponents([.day], from: start, to: today).day ?? 0
    var week = days / 7 + 1
    if week < 1 { week = 1 }
    if week > 20 { week = 20 }
    return week
}
