# reading-stats

Your e-reader's reading time, streaks and highlights, on your phone. A self-hosted companion for
[KOReader](https://koreader.rocks): the e-reader syncs to a small server you own, and you see it on
the web and in iPhone widgets.

<p>
  <img src="docs/screenshots/today.png" width="220" alt="Today: reading time, current book, streak and totals">
  <img src="docs/screenshots/books.jpg" width="220" alt="Books: a cover grid with progress">
  <img src="docs/screenshots/highlights.png" width="220" alt="Highlights: search, filters and grouping by book">
</p>
<p>
  <img src="docs/screenshots/today-charts.png" width="220" alt="Last 30 days, a 26-week calendar and a highlight of the day">
  <img src="docs/screenshots/book.png" width="220" alt="A book's page: progress, time, days read and highlights by chapter">
  <img src="docs/screenshots/widgets.png" width="220" alt="iPhone widgets: today, current book and a GitHub-style reading calendar">
</p>

*Screenshots use the demo library from `scripts/demo_data.py`.*

## What it does

- **Today**: time read today, this week, month and year, your streak, the last 30 days and a
  26-week calendar, what you're reading now, and a highlight of the day.
- **Books**: covers (from Open Library), progress, time spent and days read per book.
- **Highlights**: every highlight and note from KOReader, plus the stock Kindle reader's
  `My Clippings.txt`, grouped by book and chapter or by month, searchable. One-word dictionary
  lookups are kept apart as Words.
- **iPhone**: an app that shows the site, and widgets for the Home Screen (today, current book,
  reading calendar) and the Lock Screen.
- **No manual syncing**: highlights upload seconds after you make them, stats sync whenever Wi-Fi
  connects and every 30 minutes. Offline changes wait and go out later.

## How it works

```
e-reader (KOReader)                         your server (server.py)               you
──────────────────                          ───────────────────────               ───
Reading statistics ── statistics.sqlite3 ──▶ /dav/koreader/          ──▶ web app (/login, /)
highlightsync plugin ── highlights/*.json ─▶   (WebDAV, Basic auth)  ──▶ /api/widget ──▶ iOS widgets
```

- `server.py`: one Python file, standard library only. It is the WebDAV folder KOReader's built-in
  statistics sync writes to, and it serves the web app and its API from the same data.
- `koreader/highlightsync.koplugin`: a KOReader plugin that uploads highlights to the same
  WebDAV server and keeps statistics syncing in the background.
- `ios/`: a SwiftUI app and WidgetKit extension.

Each person runs their own server; there is no shared service. Data stays on a volume you control.

## Install

Give [INSTALL.md](INSTALL.md) to a coding agent (or follow it yourself). It covers getting
KOReader onto the device, deploying the server to Railway, configuring the device with
`scripts/configure_koreader.py`, tidying books, and building the iPhone app.

## Run it locally

```sh
scripts/demo_data.py ./demo-data
AUTH_PASSWORD=demo-password-123 DATA_DIR=./demo-data PORT=8080 python3 server.py
# open http://localhost:8080 and sign in as reader / demo-password-123
```

## Configuration

| Variable | Purpose |
|---|---|
| `AUTH_PASSWORD` | Required, 12+ characters. Password for the web app and for KOReader's WebDAV sync |
| `AUTH_USER` | Username, default `reader` |
| `SESSION_SECRET` | Signs web sessions (180 days). Defaults to one derived from the password |
| `WIDGET_TOKEN` | Read-only bearer token for `/api/widget`, used by the iOS widgets |
| `DATA_DIR` | Where data lives, default `/data`; mount a persistent volume there |
| `TZ_NAME` | IANA time zone for "today" and streaks, default `UTC` |
| `PORT` | Listen port, default `8080` |

## Security

- The browser signs in at `/login`; sessions are HttpOnly, Secure, SameSite=Lax cookies.
- WebDAV uses Basic auth (KOReader's only option); keep the server behind HTTPS.
- Failed logins are rate-limited per client, and slowed down for everyone when many fail at once.
- The widget token can only read the widget summary.

## License

MIT, see [LICENSE](LICENSE).
