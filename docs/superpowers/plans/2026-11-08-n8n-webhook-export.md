# Wysyłka transkryptów do n8n (webhook) — plan wdrożenia

Data: 2026-11-08 · Status: plan, nic nie zaimplementowane

## Cel

W Ustawieniach definiujemy webhook (URL + nagłówek autoryzacyjny). W widoku transkryptu przycisk
**Send to n8n** wysyła ustrukturyzowany JSON: transkrypt, metadane, tagi, mówców, podsumowanie.
Każdy transkrypt ma stabilne ID, po którym n8n deduplikuje (upsert).

## Decyzje (skonsultowane z Fable)

| Temat | Decyzja |
|---|---|
| ID do deduplikacji | Istniejące `TranscriptDocument.id` (stem pliku, np. `2026-11-08_101500`). Jest `let`, ponowna transkrypcja go zachowuje, system plików wymusza unikalność. |
| Wykrywanie zmian | `contentHash` = SHA-256 obiektu `transcript` (bez `sentAt`), kodowanego deterministycznie. n8n: upsert po `id`, pomija wysyłkę, gdy hash się nie zmienił. Nigdy nie kluczuje po hashu. |
| Nagłówek `Idempotency-Key` | Nie — n8n go ignoruje, kontraktem jest body. |
| Liczba webhooków | Jeden (v1). |
| Przechowywanie | URL **i** wartość nagłówka w Keychain (URL webhooka n8n działa jak token). Nazwa nagłówka w UserDefaults. |
| Tryb wysyłki | Tylko ręcznie (przycisk). Bez auto-wysyłki, bez retry. |
| Sukces | HTTP 2xx. Timeout 60 s. Bez przekierowań (nagłówek auth nie może wyciec — wzorzec `NoRedirects`). |
| Audio/wideo | Nie wysyłamy. |
| Test | Przycisk „Send test” w Ustawieniach: ta sama koperta, `event: "ping"`, `transcript: null`. |

Do potwierdzenia: jeśli kiedyś dojdzie drugi Mac albo synchronizacja przez iCloud, ID oparte na
czasie przestaje wystarczać — wtedy przed zamrożeniem kontraktu trzeba dodać trwały UUID.

## Kontrakt payloadu (schemaVersion 1)

```json
{
  "schemaVersion": 1,
  "event": "transcript.exported",          // albo "ping"
  "sentAt": "2026-11-08T10:30:00+01:00",
  "app": { "name": "meeting-transcriber", "version": "1.x", "bundleID": "com.czlonkowski.MeetingTranscriber" },
  "transcript": {
    "id": "2026-11-08_101500",
    "contentHash": "sha256:…",
    "title": "…",
    "createdAt": "…",                      // doc.date
    "recordedAt": "…" ,                    // null dla nagrań na żywo
    "durationSec": 3512.4,
    "language": "pl",
    "engine": "mai-transcribe-2",
    "sourceKind": "live",                  // live | imported
    "sourceURL": "https://meet.google.com/…",
    "tags": ["klient-x"],
    "speakers": [{ "id": 0, "name": "Romuald" }],
    "segments": [{ "start": 0.0, "end": 4.2, "speakerId": 0, "speakerName": "Romuald", "text": "…" }],
    "markdown": "…",                       // TranscriptFormatter.renderMarkdown
    "summary": { "markdown": "…", "model": "…", "generatedAt": "…" },   // albo null
    "flags": { "partialSystemCapture": false, "speakersCorrected": true }
  }
}
```

Zasady dla workflow w n8n (do opisania w `docs/MCP.md` obok albo w osobnym `docs/n8n-webhook.md`):
- Webhook w trybie **Respond immediately**, ciężka praca (CRM, LLM) po odpowiedzi — inaczej 60 s timeout
  przy sukcesie i użytkownik kliknie ponownie.
- `segments` traktować jako **zastąp całość**, nie scalaj: ponowna transkrypcja zmienia `speakerId`.
- Branch po `event` (`ping` vs `transcript.exported`).
- 3 h spotkania ≈ 1–2 MB JSON — mieści się w domyślnym limicie n8n (16 MB).

## Zmiany w kodzie

### 1. `Storage/WebhookStore.swift` (nowy)
- `WebhookStore` na wzór `AzureSpeechStore`: `loadURL/saveURL` (Keychain, konto `n8n-webhook-url`),
  `loadHeaderValue/saveHeaderValue` (Keychain, `n8n-webhook-auth`), `headerName` (UserDefaults,
  domyślnie `Authorization`), `isConfigured`.
- `StoredAPIKey` jest `private` w `KeychainHelper.swift` — zmienić na `internal` (bez innych zmian).

### 2. `Export/WebhookPayload.swift` (nowy, czysty, testowalny)
- `Codable` structy w stałej kolejności pól: `WebhookEnvelope`, `WebhookTranscript`, `Segment`, `Summary`, `Flags`.
- `static func make(from doc: TranscriptDocument, sentAt: Date) -> WebhookEnvelope`.
- `contentHash`: `JSONEncoder` z `.sortedKeys`, daty jednym formaterem ISO-8601 z offsetem,
  liczby przez strategię kodowania — haszujemy `WebhookTranscript` z pustym `contentHash`, potem go wpisujemy.
- Nowy folder `Export/` albo pliki w `Storage/` — decyzja przy implementacji (AGENTS.md wymienia tylko
  istniejące foldery; prościej `Storage/`).

### 3. `Export/WebhookClient.swift` (nowy)
- Efemeryczna `URLSession`, timeout 60 s, delegat bez przekierowań (wyciągnąć `NoRedirects` z
  `AzureOpenAIClient.swift` do współdzielonego pliku).
- `POST`, `Content-Type: application/json`, nagłówek auth, gdy ustawiony.
- Błędy: brak konfiguracji, sieć, HTTP ≠ 2xx (status + pierwsze ~300 znaków body). Logi przez `Log`, bez wartości nagłówka.
- Walidacja URL: tylko `https` (wyjątek: `http://localhost` do testów).

### 4. Model: `TranscriptDocument`
- Nowe opcjonalne pola: `webhookSentAt: Date?`, `webhookContentHash: String?`.
- Dopisać je do własnego `init(from:)` (`decodeIfPresent`) i do `applyRetranscription` (przenieść wartości —
  hash i tak się zmieni, więc UI pokaże „zmieniono od wysyłki”).
- Nie wchodzą do payloadu, więc nie wpływają na hash.

### 5. `AppState`
- `func sendToWebhook(documentID:) async` — buduje payload, wysyła, po 2xx zapisuje `webhookSentAt` +
  `webhookContentHash` przez `TranscriptStore.save`, błąd do `lastError`.
- Stan `webhookSendingIDs: Set<String>` blokujący podwójne kliknięcie.
- `func sendWebhookTest() async throws`.

### 6. UI
- **Settings**: nowa zakładka „Integrations” (`Tab("Integrations", systemImage: "arrow.up.forward.app")`):
  URL (SecureField z podglądem), nazwa nagłówka, wartość (SecureField), „Send test” z wynikiem inline,
  krótka notka o trybie Respond immediately.
- **TranscriptDetailView**: przycisk „Send to n8n” w dolnym pasku obok „Save as .md…” / „Copy as Markdown”,
  ten sam styl (`.glassProminent`). Stany: niedostępny (brak konfiguracji → podpowiedź „Configure in Settings”),
  wysyłanie (ProgressView), „Sent ✓” (data w `help`), „Changed since sent” (hash ≠ zapisany) → ponowne wysłanie.
  Etykieta „Send to n8n” — konfigurowalna nazwa niepotrzebna w v1.

### 7. (Opcjonalnie, później) MCP
- Narzędzie `send_to_webhook` w `MCPTools` — tylko jeśli będzie potrzebne; nie w v1.

## Testy (`MeetingTranscriberTests/`)
- `WebhookPayloadTests`: mapowanie pól (nazwy mówców w segmentach, `summary` null, `recordedAt` null),
  hash deterministyczny (dwa wywołania = ten sam hash), hash zmienia się po zmianie tytułu/tagów/summary,
  nie zmienia się po zmianie `sentAt` i pól `webhook*`.
- `TranscriptStoreTests`: stary JSON bez nowych pól się dekoduje; round-trip z polami.
- `WebhookClientTests`: `URLProtocol` stub — nagłówek auth ustawiony, 2xx = sukces, 401/500 = błąd z treścią,
  302 nie jest śledzony.

## Weryfikacja ręczna
1. Webhook testowy w n8n, Header Auth credential, Respond immediately.
2. „Send test” → wykonanie z `event: ping`.
3. Wysłanie transkryptu z summary i tagami → sprawdzić pola w n8n, „Sent ✓” w UI.
4. Zmiana tagu → „Changed since sent” → ponowna wysyłka, ten sam `id`, inny `contentHash`.
5. Zły nagłówek → 403 widoczny w UI. Light/dark dla nowych kontrolek.

## Kolejność
1. `StoredAPIKey` internal + `WebhookStore`
2. `WebhookPayload` + testy
3. `WebhookClient` (+ wydzielenie `NoRedirects`) + testy
4. Pola modelu + dekoder + retranskrypcja + testy
5. `AppState`
6. UI: Settings, potem przycisk w transkrypcie
7. `xcodegen generate`, build, testy, `scripts/reinstall.sh`, test ręczny z n8n
8. Workflow w n8n (osobno, po zamrożeniu kontraktu)
