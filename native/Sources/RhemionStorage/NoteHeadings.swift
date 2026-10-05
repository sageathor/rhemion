import Foundation

/// The words in the week and day headings of the history and export notes. They follow the Mac's
/// language: Russian on a Russian system, English everywhere else. Shared by the runtime and the app so
/// both render the same bytes (export re-adoption compares notes byte for byte).
public struct NoteHeadings: Sendable, Equatable {
    /// Weekday names, Sunday first (the order of `Calendar.component(.weekday, …)`).
    let weekdays: [String]
    let week: String
    let russianDates: Bool

    public static let english = NoteHeadings(
        weekdays: ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"],
        week: "Week", russianDates: false)
    public static let russian = NoteHeadings(
        weekdays: ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"],
        week: "Неделя", russianDates: true)

    /// The headings for the user's preferred language.
    public static var system: NoteHeadings { forLanguage(Locale.preferredLanguages.first ?? "en") }

    static func forLanguage(_ identifier: String) -> NoteHeadings {
        identifier.lowercased().hasPrefix("ru") ? .russian : .english
    }

    func weekHeading(_ week: Int) -> String { "## \(self.week) \(week)" }

    /// "### понедельник 05.10.2026" (Russian) or "### Monday 2026-10-05" (English, unambiguous order).
    func dayHeading(weekday: Int, day: DateComponents) -> String {
        let name = weekdays[weekday - 1]
        return russianDates
            ? String(format: "### %@ %02d.%02d.%04d", name, day.day!, day.month!, day.year!)
            : String(format: "### %@ %04d-%02d-%02d", name, day.year!, day.month!, day.day!)
    }
}
