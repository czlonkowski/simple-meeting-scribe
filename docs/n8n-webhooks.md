# n8n webhooks

Meeting Transcriber talks to n8n through two webhooks, configured in
**Settings → Integrations**. Both use the same auth header (name + value, kept in
the Keychain) and refuse redirects.

## 1. Export — `transcript.exported`

POSTed by **Send to n8n** on a transcript, or automatically after transcription
(and after the automatic summary) when **Send new transcripts automatically** is on.
Set the n8n Webhook node to **Respond immediately**; the app waits up to 60 s.

```json
{
  "schemaVersion": 1,
  "event": "transcript.exported",              // or "ping" from "Send test" (transcript: null)
  "sentAt": "2026-11-08T19:32:58Z",
  "app": { "name": "meeting-transcriber", "version": "0.1.0", "bundleID": "…", "timeZone": "Europe/Warsaw" },
  "transcript": {
    "id": "2026-11-08_203256",                  // stable: upsert on this
    "contentHash": "sha256:…",                  // changes when content changes
    "title": "…", "createdAt": "…", "recordedAt": null, "durationSec": 11.2,
    "language": "pl", "engine": "mai-transcribe-2", "sourceKind": "live", "sourceURL": null,
    "tags": [], "flags": { "partialSystemCapture": false, "speakersCorrected": false },
    "speakers": [{ "id": 1, "name": "Romuald" }],
    "calendarEvent": null,                      // the event the lookup matched, see below
    "summary": { "markdown": "…", "model": "azure/gpt61terra", "generatedAt": "…" },
    "markdown": "…",                            // full document incl. summary
    "segments": [{ "start": 0.8, "end": 10.5, "speakerId": 1, "speakerName": "Romuald", "text": "…" }]
  }
}
```

Rules: upsert on `transcript.id`, skip when `contentHash` is unchanged, treat
`segments` as replace-all (re-transcription renumbers speakers). Dates are UTC.

## 2. Meeting lookup — `meeting.lookup`

POSTed at the start of every summary (manual and automatic) when **Look up the
calendar event before summarizing** is on. The workflow must answer with a
**Respond to Webhook** node. The app waits at most **8 s**; on any failure it
summarizes without calendar context. Automatic summaries ask once per transcript
(a failed lookup is retried); a manual summary always asks again.

Request:

```json
{
  "schemaVersion": 1,
  "event": "meeting.lookup",
  "transcriptId": "2026-11-08_203256",
  "start": "2026-11-08T19:32:43Z",              // recording start (UTC)
  "end": "2026-11-08T19:32:54Z",
  "windowStart": "2026-11-08T19:12:43Z",        // start − 20 min: list events in this range
  "windowEnd": "2026-11-08T19:32:54Z",
  "durationSec": 11.2,
  "timeZone": "Europe/Warsaw",
  "sourceKind": "live",
  "sourceURL": "https://meet.google.com/abc-defg-hij?authuser=0",
  "meetCode": "abc-defg-hij",                   // null unless Google Meet
  "title": "Google Meet — abc-defg-hij",
  "language": "pl"
}
```

Response — every event overlapping `windowStart … windowEnd`; the app picks one:

```json
{
  "events": [
    {
      "id": "google-event-id",
      "title": "Oferta dla klienta",
      "start": "2026-11-08T20:30:00+01:00",       // ISO-8601, any offset; "2026-11-08" for all-day
      "end": "2026-11-08T21:00:00+01:00",
      "allDay": false,
      "recurringEventId": null,
      "status": "confirmed",                     // cancelled events are ignored
      "selfResponseStatus": "accepted",          // declined events are ignored
      "organizer": { "name": "Jan Kowalski", "email": "jan@example.com" },
      "attendees": [
        { "name": "Anna Nowak", "email": "anna@example.com", "responseStatus": "accepted", "self": false }
      ],
      "description": "…",                        // trimmed to 800 chars; join links / PINs removed
      "location": "…",
      "meetingURL": "https://meet.google.com/abc-defg-hij"   // Google's hangoutLink
    }
  ]
}
```

`{ "events": [] }` (or `[]`) means no meeting. How the app chooses: same Meet
code first, then the largest overlap with the recording, then the nearest start
(within 20 min). All-day, cancelled and self-declined events are skipped, and
declined attendees are dropped.

Reference workflow: Webhook (Header Auth, respond using the Respond to Webhook node) →
Google Calendar "Get many events" on your calendar → Code "Build events" (maps to the
shape below) → Respond 200 `{events}`, or 502 when the Calendar node errors.

Google Calendar → this shape (node "Get many events", Return All, `timeMin` =
`windowStart`, `timeMax` = `windowEnd`, Single Events on):

| response field | Google Calendar field |
|---|---|
| `start` / `end` | `start.dateTime ?? start.date` / `end.dateTime ?? end.date` |
| `allDay` | `!!start.date` |
| `title` | `summary` |
| `meetingURL` | `hangoutLink` |
| `selfResponseStatus` | `attendees.find(a => a.self)?.responseStatus` |
| `attendees[].name` | `displayName` |

What the app does with the match: the attendee names go to the speaker-naming
pass (with a warning that attendees may not have spoken), title + time +
organizer + invitees + description go before the transcript in the summary
pass, and the event title is a hint for the title pass. The match is shown
under the transcript header and included in the export as `calendarEvent`.
