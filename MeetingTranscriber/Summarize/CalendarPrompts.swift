import Foundation

/// Prompt blocks built from the calendar event matched to a meeting. Each
/// pass gets only what it needs: names for speaker identification, the full
/// context for the summary, the event title for the title pass.
enum CalendarPrompts {

    /// Appended to the speaker-identification prompt. Warns that attendees
    /// may not have spoken, so the model doesn't hand out names to fill slots.
    static func participantsBlock(for language: TranscriptionLanguage,
                                  event: CalendarEvent,
                                  labelCount: Int) -> String? {
        let names = event.participantPromptLabels
        guard !names.isEmpty else { return nil }
        let list = names.map { "- \($0)" }.joined(separator: "\n")
        switch language {
        case .english:
            return """
                Calendar invite "\(event.title)" lists \(names.count) other attendee(s) for \(labelCount) speaker label(s). \
                Attendees may not have spoken, and people not on the invite may have. Use a name from this list only \
                when the conversation supports it (someone is addressed by name, introduces themselves, or the role fits); \
                otherwise write 'unknown'. Write the name as people use it in the conversation; add the surname when \
                two attendees share a first name.
                Attendees:
                \(list)
                """
        case .polish:
            return """
                Zaproszenie z kalendarza „\(event.title)" ma \(names.count) innych uczestnika/ów na \(labelCount) etykiet(y) mówców. \
                Nie każdy uczestnik musiał się odezwać, a mówić mogły też osoby spoza zaproszenia. Użyj imienia z tej listy \
                tylko wtedy, gdy rozmowa to potwierdza (ktoś zwraca się po imieniu, przedstawia się albo pasuje rola); \
                w przeciwnym razie napisz 'unknown'. Podaj imię tak, jak pada w rozmowie; dodaj nazwisko, gdy dwóch \
                uczestników ma to samo imię.
                Uczestnicy:
                \(list)
                """
        }
    }

    /// Placed before the transcript in the summary prompt.
    static func contextBlock(for language: TranscriptionLanguage,
                             event: CalendarEvent,
                             timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: language == .polish ? "pl_PL" : "en_US")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let time = "\(f.string(from: event.start))–\(timeOnly(event.end, timeZone))"
        let names = event.participantPromptLabels
        let organizer = event.organizer?.promptLabel
        var lines: [String] = []
        switch language {
        case .english:
            lines.append("Meeting context from the calendar (may be incomplete; the transcript wins on conflicts):")
            lines.append("- Title: \(event.title)")
            lines.append("- Scheduled: \(time)")
            if let organizer { lines.append("- Organizer: \(organizer)") }
            if !names.isEmpty { lines.append("- Invited: \(names.joined(separator: ", ")) (not all may have attended)") }
            if let location = event.location, !location.isEmpty { lines.append("- Location: \(location)") }
            if let description = event.description, !description.isEmpty { lines.append("- Description:\n\(description)") }
        case .polish:
            lines.append("Kontekst spotkania z kalendarza (może być niepełny; przy sprzeczności decyduje transkrypcja):")
            lines.append("- Tytuł: \(event.title)")
            lines.append("- Termin: \(time)")
            if let organizer { lines.append("- Organizator: \(organizer)") }
            if !names.isEmpty { lines.append("- Zaproszeni: \(names.joined(separator: ", ")) (nie wszyscy musieli być obecni)") }
            if let location = event.location, !location.isEmpty { lines.append("- Miejsce: \(location)") }
            if let description = event.description, !description.isEmpty { lines.append("- Opis:\n\(description)") }
        }
        return lines.joined(separator: "\n")
    }

    /// Appended to the title instruction: keep a specific calendar title,
    /// enrich a generic or recurring one with the topic.
    static func titleHint(for language: TranscriptionLanguage, event: CalendarEvent) -> String {
        let recurring = event.isRecurring
        switch language {
        case .english:
            return """
                • The calendar title is "\(event.title)"\(recurring ? " (a recurring meeting)" : ""). If it is specific, \
                keep it as the title. If it is generic or recurring, write "\(event.title) — <main topic>".
                """
        case .polish:
            return """
                • Tytuł w kalendarzu to „\(event.title)"\(recurring ? " (spotkanie cykliczne)" : ""). Jeśli jest konkretny, \
                użyj go jako tytułu. Jeśli jest ogólny albo cykliczny, napisz „\(event.title) — <główny temat>".
                """
        }
    }

    private static func timeOnly(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
