import Foundation

public enum DailySchedule {
    public static func dayKey(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func scheduledTime(on date: Date, settings: AppSettings) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = settings.timeZone
        let start = calendar.startOfDay(for: date)
        return calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: start, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? start
    }
    public static func shouldRefresh(now: Date, settings: AppSettings, latest: BriefEdition?, retry: RetryState = RetryState()) -> Bool {
        guard settings.hasCompletedSetup, settings.automaticUpdates,
              retry.permitsAutomaticGeneration(now: now, timeZone: settings.timeZone),
              now >= scheduledTime(on: now, settings: settings),
              retry.nextAttempt.map({ now >= $0 }) ?? true else { return false }
        return latest?.isDemo == true || latest?.dayKey != dayKey(for: now, timeZone: settings.timeZone)
            || (latest?.createdAt ?? .distantPast) < scheduledTime(on: now, settings: settings)
    }
}
