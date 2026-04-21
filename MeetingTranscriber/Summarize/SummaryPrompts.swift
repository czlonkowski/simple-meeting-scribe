import Foundation

/// Per-language prompt templates. Two calls per summarization (summary then
/// action items) keep streaming UX simple and robust — no JSON parsing,
/// each block lands in its own UI card as it generates.
enum SummaryPrompts {

    // MARK: - System instructions (user-editable via Settings).

    static let defaultSystemEnglish =
        "You are a meeting-notes assistant. Be concise, factual, and faithful to the transcript. " +
        "Use the same language as the transcript. Preserve names, technical terms, and numbers exactly as they appear."

    static let defaultSystemPolish =
        "Jesteś asystentem do notowania spotkań. Bądź zwięzły, rzeczowy i wierny transkrypcji. " +
        "Odpowiadaj w języku transkrypcji. Zachowaj nazwy, terminy techniczne i liczby dokładnie tak, jak się pojawiają."

    // MARK: - Per-call user prompts.

    static func summaryInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return "Write a concise summary of the meeting transcript below in 3–6 sentences. No bullets, no headers — one flowing paragraph."
        case .polish:
            return "Napisz zwięzłe streszczenie poniższej transkrypcji spotkania w 3–6 zdaniach. Bez wypunktowań, bez nagłówków — jeden płynny akapit."
        }
    }

    static func titleInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return """
                Generate a concise meeting title from the transcript below.

                Rules:
                • 3–8 words, Title Case.
                • No quotes, no trailing punctuation, no preamble.
                • Prefer concrete nouns from the meeting (project, topic, decision) over generic words like "Discussion" or "Meeting".
                • Output the title on a single line. Nothing else.
                """
        case .polish:
            return """
                Wygeneruj zwięzły tytuł spotkania na podstawie poniższej transkrypcji.

                Zasady:
                • 3–8 słów, z wielkiej litery tam, gdzie to naturalne.
                • Bez cudzysłowów, bez kropki na końcu, bez wstępu.
                • Preferuj konkretne rzeczowniki ze spotkania (projekt, temat, decyzja) zamiast ogólników typu "Spotkanie" czy "Rozmowa".
                • Zwróć tytuł w jednej linii. Nic więcej.
                """
        }
    }

    /// Clean up a model-generated title: strip quotes, markdown, trailing
    /// punctuation, and collapse to the first line (models sometimes leak
    /// explanations below the answer).
    static func sanitizeTitle(_ raw: String) -> String {
        var t = stripThinking(raw)
        if let nl = t.firstIndex(where: \.isNewline) {
            t = String(t[..<nl])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip wrapping quotes / backticks / asterisks.
        while let first = t.first, "\"'`*".contains(first) { t.removeFirst() }
        while let last = t.last, "\"'`*".contains(last) { t.removeLast() }
        // Strip leading markdown headers.
        while t.hasPrefix("#") { t.removeFirst() }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing period.
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    static func actionItemsInstruction(for language: TranscriptionLanguage) -> String {
        switch language {
        case .english:
            return """
                Extract ONLY future commitments and next steps from the transcript below.

                An action item is something someone explicitly COMMITS TO DO. It requires:
                • a future-tense verb (will, going to, need to, should, let's, I'll …), OR
                • an assignment (“X will handle Y”), OR
                • a deadline or next meeting.

                It is NOT:
                • a description of the current situation
                • an opinion, observation, fact, or conclusion
                • a question
                • something that already happened
                • a paraphrase of what someone said

                Output format (bullets only, no preamble, no headings):
                - [owner] task (due: …)     ← when an owner or deadline is stated
                - task                       ← otherwise
                - None.                      ← if the transcript contains NO real commitments

                When in doubt, omit. A meeting with 0 action items is common and expected.
                """
        case .polish:
            return """
                Wyodrębnij WYŁĄCZNIE zobowiązania i kolejne kroki z poniższej transkrypcji.

                Zadaniem do wykonania jest coś, do czego ktoś się wyraźnie ZOBOWIĄZUJE. Wymaga:
                • czasu przyszłego lub trybu rozkazującego (zrobię, wyślę, trzeba, musimy, ustalmy…), LUB
                • przydzielenia osoby („X zajmie się Y”), LUB
                • terminu albo kolejnego spotkania.

                NIE jest zadaniem:
                • opis bieżącej sytuacji
                • opinia, obserwacja, fakt lub wniosek
                • pytanie
                • coś, co już się wydarzyło
                • parafraza czyjejś wypowiedzi

                Format (tylko punkty, bez wstępu, bez nagłówków):
                - [osoba] zadanie (termin: …)   ← gdy podana jest osoba lub termin
                - zadanie                        ← w przeciwnym razie
                - Brak.                          ← gdy transkrypcja NIE zawiera żadnych rzeczywistych zobowiązań

                Jeżeli masz wątpliwości, pomiń. Spotkanie bez zadań do wykonania jest normalne.
                """
        }
    }

    /// Strip any `<think>…</think>` blocks the model might still emit.
    /// Safe to call on streaming partials: if the opening tag was seen but the
    /// closing one hasn't arrived yet, everything from `<think>` onward is
    /// hidden until the matching close tag lands (or stream ends).
    static func stripThinking(_ raw: String) -> String {
        var out = raw
        // Remove complete <think>...</think> blocks first.
        while let open = out.range(of: "<think>"),
              let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        // For a streaming partial: if <think> opened without a close yet,
        // hide everything from that point so the UI doesn't show reasoning.
        if let open = out.range(of: "<think>") {
            out.removeSubrange(open.lowerBound..<out.endIndex)
        }
        return out
    }

    /// Parse the bullet list the model returned into a clean array of strings.
    /// Strips leading `-` / `•` / `*`, dedents, and drops the "None." sentinel.
    static func parseActionItems(_ raw: String) -> [String] {
        let lines = raw.split(whereSeparator: \.isNewline).map(String.init)
        var out: [String] = []
        for line in lines {
            var s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            if let first = s.first, "-•*·".contains(first) {
                s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            guard !s.isEmpty else { continue }
            let lower = s.lowercased()
            if lower == "none." || lower == "none" || lower == "brak." || lower == "brak" { continue }
            out.append(s)
        }
        return out
    }
}
