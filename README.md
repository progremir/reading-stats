# reading-stats

Your e-reader's reading time, streaks and highlights, on your phone. A self-hosted companion for
[KOReader](https://koreader.rocks): the e-reader syncs to a small server you own, and you see it on
the web and in iPhone widgets. One server can serve a whole household, with a separate account
for each reader.

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
- **Several readers**: each person signs in with their own account and sees only their own
  books, stats and highlights.

## How it works

```
e-reader (KOReader)                         your server (server.py)               you
──────────────────                          ───────────────────────               ───
Reading statistics ── statistics.sqlite3 ──▶ /dav/koreader/          ──▶ web app (/login, /)
highlightsync plugin ── highlights/*.json ─▶   (WebDAV, Basic auth)  ──▶ /api/widget ──▶ iOS widgets
```

Every request is tied to one account: WebDAV and the web app by username and password, the
widgets by that account's widget token. `/dav/` is that account's own folder.

- `server.py`: one Python file, standard library only. It is the WebDAV folder KOReader's built-in
  statistics sync writes to, and it serves the web app and its API from the same data.
- `koreader/highlightsync.koplugin`: a KOReader plugin that uploads highlights to the same
  WebDAV server and keeps statistics syncing in the background.
- `ios/`: a SwiftUI app and WidgetKit extension.

There is no shared service: you run the server, and data stays on a volume you control. A
household can share one server, with an account per reader.

## Install

Give [INSTALL.md](INSTALL.md) to a coding agent (or follow it yourself). It covers getting
KOReader onto the device, deploying the server to Railway, adding more readers, configuring each
device with `scripts/configure_koreader.py`, tidying books, building the iPhone app, and merging
two existing servers into one.

## Run it locally

```sh
scripts/demo_data.py ./demo-data
AUTH_PASSWORD=demo-password-123 DATA_DIR=./demo-data PORT=8080 python3 server.py
# open http://localhost:8080 and sign in as reader / demo-password-123
```

With a second, empty account:

```sh
USERS='{"alice": {"password": "alice-password-123", "widget_token": "alice-token"}}' \
  AUTH_PASSWORD=demo-password-123 DATA_DIR=./demo-data PORT=8080 python3 server.py
# sign in as alice / alice-password-123; she starts with an empty library
```

## Configuration

| Variable | Purpose |
|---|---|
| `AUTH_PASSWORD` | Required, 12+ characters. The first account's password, for the web app and KOReader's WebDAV sync |
| `AUTH_USER` | The first account's username, default `reader` |
| `WIDGET_TOKEN` | The first account's read-only bearer token for `/api/widget`, used by its iOS widgets |
| `USERS` | More accounts, as JSON (see below) |
| `SESSION_SECRET` | Signs web sessions (180 days) for every account. Defaults to one derived from `AUTH_PASSWORD` |
| `DATA_DIR` | Where data lives, default `/data`; mount a persistent volume there |
| `TZ_NAME` | IANA time zone for "today" and streaks, default `UTC`; accounts can override it |
| `PORT` | Listen port, default `8080` |

### Accounts

The first account comes from `AUTH_USER`, `AUTH_PASSWORD` and `WIDGET_TOKEN`, so a one-person
server needs nothing else. Add more readers with `USERS`, a JSON object keyed by username:

```json
{
  "alice": {"password": "at-least-12-chars", "widget_token": "random-hex", "tz": "Europe/Berlin"},
  "bob":   {"password": "another-12-chars",  "widget_token": "other-random-hex"}
}
```

- `password`: required, 12+ characters. Used for the web login and the KOReader sync.
- `widget_token`: optional, for that person's iPhone widgets. Every account needs a different one.
- `tz`: optional, defaults to `TZ_NAME`.

Usernames must be letters, digits and underscores, not starting with a digit. The server refuses
to start if a name repeats, a password is short, or two accounts share a widget token.

Where data lives:

| Account | WebDAV folder |
|---|---|
| first (`AUTH_USER`) | `DATA_DIR/dav` |
| each `USERS` entry | `DATA_DIR/users/<name>/dav` |
| everyone (cover cache) | `DATA_DIR/covers` |

Adding accounts later doesn't move the first account's data, so turning a one-person server into
a shared one only means setting `USERS`.

## Security

- The browser signs in at `/login`; sessions are HttpOnly, Secure, SameSite=Lax cookies.
- WebDAV uses Basic auth (KOReader's only option); keep the server behind HTTPS.
- Failed logins are rate-limited per client, and slowed down for everyone when many fail at once.
- A widget token can only read its own account's widget summary.
- Accounts can't see each other's data: WebDAV, the web app and widgets are scoped to the signed-in
  account, and WebDAV paths can't escape that account's folder.
- Login checks every account in constant time, so response timing doesn't reveal which usernames exist.

## License

MIT, see [LICENSE](LICENSE).
