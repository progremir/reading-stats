"""Reading stats: a tiny WebDAV store for KOReader's statistics sync, plus a dashboard.

KOReader (Reading statistics > Settings > Cloud sync) GETs and PUTs
statistics.sqlite3 in a WebDAV folder. This serves that folder at /dav/
and reads the same file to render the dashboard at /. The highlightsync
KOReader plugin (koreader/) PUTs per-book highlights next to it.
Accounts, sessions and device passwords live in auth.py; every request
is served from the signed-in account's own folder.
"""

import base64
import datetime as dt
import email.utils
import hashlib
import html
import json
import os
import sqlite3
import tempfile
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

from auth import SESSION_DAYS as AUTH_SESSION_DAYS, Auth, AuthError

ROOT = Path(os.environ.get("DATA_DIR", "/data"))
TZ = ZoneInfo(os.environ.get("TZ_NAME", "UTC"))
PORT = int(os.environ.get("PORT", "8080"))
STATS_PATH = os.environ.get("STATS_PATH", "koreader/statistics.sqlite3")
HIGHLIGHTS_PATH = os.environ.get("HIGHLIGHTS_PATH", "koreader/highlights")
MAX_UPLOAD = 512 * 1024 * 1024
COOKIE = "rs_session"

ROOT.mkdir(parents=True, exist_ok=True)
AUTH = Auth(ROOT, TZ)
_imported = AUTH.import_from_env(os.environ)
if _imported:
    print("imported accounts from the environment: %s. They now live in %s; AUTH_PASSWORD, "
          "WIDGET_TOKEN and USERS are no longer read." % (", ".join(_imported), AUTH.path), flush=True)
if not AUTH.count_users():
    raise SystemExit("No accounts yet. Set AUTH_PASSWORD (and optionally AUTH_USER) for the first start: "
                     "it becomes the first admin account.")
LOGIN_WINDOW, LOGIN_MAX_FAILS = 15 * 60, 10
login_failures = {}  # ip -> [timestamps]
recent_failures = []  # every failed attempt, all clients


def note_failure(ip):
    now = time.time()
    login_failures.setdefault(ip, []).append(now)
    recent_failures.append(now)
    del recent_failures[:-1000]
    # Client IPs can be spoofed through forwarding headers, so also slow everyone's
    # failed attempts down once many fail in a short time.
    if sum(1 for t in recent_failures if now - t < 60) > 20:
        time.sleep(2)


def ip_locked(ip):
    now = time.time()
    recent = [t for t in login_failures.get(ip, []) if now - t < LOGIN_WINDOW]
    login_failures[ip] = recent
    return len(recent) >= LOGIN_MAX_FAILS

COVERS_DIR = ROOT / "covers"  # shared: covers are public and keyed by title
COVERS_DIR.mkdir(parents=True, exist_ok=True)
INDEX_HTML = (Path(__file__).parent / "index.html").read_text()
LOGIN_HTML = (Path(__file__).parent / "login.html").read_text()
ACCOUNT_HTML = (Path(__file__).parent / "account.html").read_text()
ADMIN_HTML = (Path(__file__).parent / "admin.html").read_text()


def etag_of(path):
    st = path.stat()
    return '"%x-%x"' % (st.st_mtime_ns, st.st_size)


def dav_path(url_path, user):
    """Map /dav/<rel> to a file under the user's folder, refusing anything that escapes it."""
    rel = urllib.parse.unquote(url_path[len("/dav"):]).lstrip("/")
    root = user.dav.resolve()
    target = (root / rel).resolve()
    if target != root and root not in target.parents:
        return None
    return target


def propfind_entry(href, path):
    st = path.stat()
    modified = email.utils.formatdate(st.st_mtime, usegmt=True)
    if path.is_dir():
        rtype, length = "<d:resourcetype><d:collection/></d:resourcetype>", ""
    else:
        rtype = "<d:resourcetype/>"
        length = "<d:getcontentlength>%d</d:getcontentlength>" % st.st_size
    return (
        "<d:response><d:href>%s</d:href><d:propstat><d:prop>%s%s"
        "<d:getlastmodified>%s</d:getlastmodified></d:prop>"
        "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
        % (html.escape(urllib.parse.quote(href)), rtype, length, modified)
    )


def compute_stats(user):
    tz = user.tz
    db_path = user.dav / STATS_PATH
    if not db_path.exists():
        return {"empty": True}
    # immutable: never read or create -wal/-shm files next to the uploaded db
    con = sqlite3.connect("file:%s?mode=ro&immutable=1" % db_path, uri=True)
    try:
        rows = con.execute(
            "SELECT id_book, start_time, duration FROM page_stat_data WHERE duration > 0"
        ).fetchall()
        books = con.execute(
            """SELECT b.id, b.title, b.authors, b.md5, b.pages, b.last_open,
                      COALESCE(SUM(p.duration), 0),
                      COUNT(DISTINCT p.page),
                      MAX(p.total_pages)
               FROM book b LEFT JOIN page_stat_data p ON p.id_book = b.id
               GROUP BY b.id"""
        ).fetchall()
        # Pages turned per day (one row per page visit).
        page_rows = con.execute("SELECT start_time FROM page_stat_data").fetchall()
    finally:
        con.close()

    now = dt.datetime.now(tz)
    today = now.date()
    by_day = {}
    book_days, book_first = {}, {}
    for bid, start, duration in rows:
        day = dt.datetime.fromtimestamp(start, tz).date()
        by_day[day] = by_day.get(day, 0) + duration
        book_days.setdefault(bid, set()).add(day)
        book_first[bid] = min(book_first.get(bid, start), start)
    pages_by_day = {}
    for (start,) in page_rows:
        day = dt.datetime.fromtimestamp(start, tz).date()
        pages_by_day[day] = pages_by_day.get(day, 0) + 1

    def seconds_since(start_day):
        return sum(s for d, s in by_day.items() if d >= start_day)

    streak, day = 0, today
    if day not in by_day:
        day -= dt.timedelta(days=1)  # today not read yet doesn't break the streak
    while by_day.get(day, 0) >= 60:
        streak += 1
        day -= dt.timedelta(days=1)

    best, run, prev = 0, 0, None
    for d in sorted(k for k, v in by_day.items() if v >= 60):
        run = run + 1 if prev and d - prev == dt.timedelta(days=1) else 1
        best, prev = max(best, run), d

    days = []
    for i in range(181, -1, -1):
        d = today - dt.timedelta(days=i)
        days.append({"date": d.isoformat(), "seconds": by_day.get(d, 0), "pages": pages_by_day.get(d, 0)})

    book_list = []
    for bid, title, authors, md5, pages, last_open, secs, read_pages, total_pages in books:
        total = pages or total_pages or 0
        book_list.append({
            "title": title or "Untitled",
            "authors": (authors or "").replace("\n", ", "),
            "md5": md5,
            "days": len(book_days.get(bid, ())),
            "first_read": dt.datetime.fromtimestamp(book_first[bid], tz).isoformat() if bid in book_first else None,
            "seconds": secs,
            "pages_read": read_pages,
            "pages": total,
            "progress": min(1, read_pages / total) if total else 0,
            "last_open": dt.datetime.fromtimestamp(last_open, tz).isoformat() if last_open else None,
        })
    book_list.sort(key=lambda b: b["last_open"] or "", reverse=True)

    week_start = today - dt.timedelta(days=today.weekday())
    return {
        "empty": False,
        "updated": dt.datetime.fromtimestamp(db_path.stat().st_mtime, tz).isoformat(),
        "today": by_day.get(today, 0),
        "week": seconds_since(week_start),
        "month": seconds_since(today.replace(day=1)),
        "year": seconds_since(today.replace(month=1, day=1)),
        "total": sum(by_day.values()),
        "pages_total": sum(pages_by_day.values()),
        "streak": streak,
        "best_streak": best,
        "days_read": sum(1 for v in by_day.values() if v >= 60),
        "days": days,
        "books": book_list,
    }


def title_key(title):
    return " ".join(title.casefold().replace("_", ":").split())


def book_id(title):
    return hashlib.sha1(title_key(title).encode()).hexdigest()[:12]


def compute_library(user):
    """Every book seen in reading stats or highlights, with its stats and highlights."""
    stats = compute_stats(user)
    hl = compute_highlights(user)
    books = {}
    by_md5 = {}
    for b in stats.get("books", []):
        if not b["seconds"] or b["title"].startswith("KOReader Quickstart"):
            continue
        entry = dict(b, highlights=[])
        books[title_key(b["title"])] = entry
        if b.get("md5"):
            by_md5[b["md5"]] = entry
    for h in hl["books"]:
        entry = by_md5.get(h.get("md5")) or books.get(title_key(h["title"]))
        if entry is None:
            entry = {"title": h["title"], "authors": h["authors"], "seconds": 0, "pages_read": 0, "pages": 0,
                     "progress": 0, "last_open": None, "days": 0, "first_read": None, "highlights": []}
            books[title_key(h["title"])] = entry
        entry["highlights"].extend(h["highlights"])
        entry["authors"] = entry["authors"] or h["authors"]
    out = []
    for b in books.values():
        b["id"] = book_id(b["title"])
        b["highlights"].sort(key=lambda x: (x.get("loc") is None, x.get("loc") or 0, x.get("datetime") or ""))
        dates = [x["datetime"] for x in b["highlights"] if x.get("datetime")]
        b["last_activity"] = max([d for d in [b.get("last_open")] + dates if d] or [""])
        b["finished"] = b["progress"] >= 0.97
        b.pop("md5", None)
        out.append(b)
    out.sort(key=lambda b: b["last_activity"], reverse=True)
    stats.pop("books", None)
    return {"stats": stats, "books": out}


def fetch_cover(title, authors):
    """Look a cover up on Open Library; returns JPEG bytes or None."""
    q = {"title": title.split(":")[0], "limit": "1", "fields": "cover_i"}
    if authors:
        q["author"] = authors.split(",")[0]
    for params in (q, {k: v for k, v in q.items() if k != "author"}):
        try:
            url = "https://openlibrary.org/search.json?" + urllib.parse.urlencode(params)
            req = urllib.request.Request(url, headers={"User-Agent": "reading-stats"})
            docs = json.load(urllib.request.urlopen(req, timeout=10)).get("docs") or []
            cover = docs and docs[0].get("cover_i")
            if cover:
                req = urllib.request.Request("https://covers.openlibrary.org/b/id/%d-M.jpg?default=false" % cover,
                                             headers={"User-Agent": "reading-stats"})
                return urllib.request.urlopen(req, timeout=15).read()
        except (OSError, ValueError) as e:
            print("cover lookup failed for %r: %s" % (title, e), flush=True)
            return None
    return None


def cover_for(bid, user):
    if len(bid) != 12 or any(c not in "0123456789abcdef" for c in bid):
        return None
    path = COVERS_DIR / (bid + ".jpg")
    miss = COVERS_DIR / (bid + ".none")
    if path.exists():
        return path.read_bytes()
    if miss.exists() and time.time() - miss.stat().st_mtime < 86400:
        return None
    book = next((b for b in compute_library(user)["books"] if b["id"] == bid), None)
    if not book:
        return None
    data = fetch_cover(book["title"], book["authors"])
    if data:
        path.write_bytes(data)
    else:
        miss.touch()
    return data


def compute_widget(user):
    """The small payload the iOS widget shows."""
    lib = compute_library(user)
    st = lib["stats"]
    reading = next((b for b in lib["books"] if b.get("last_open") and not b["finished"] and b["seconds"]), None)
    return {
        "today": st.get("today", 0),
        "week": st.get("week", 0),
        "month": st.get("month", 0),
        "streak": st.get("streak", 0),
        "last7": [d["seconds"] for d in st.get("days", [])[-7:]],
        "days": [d["seconds"] for d in st.get("days", [])],  # oldest first, ends today
        "first_day": (st.get("days") or [{}])[0].get("date"),
        "updated": st.get("updated"),
        "book": reading and {"title": reading["title"], "authors": reading["authors"],
                             "progress": reading["progress"], "id": reading["id"]},
    }


def parse_clippings(text):
    """Parse the stock Kindle "My Clippings.txt" into highlights grouped by title."""
    books = {}
    seen = set()
    for entry in text.replace("\ufeff", "").split("=========="):
        lines = [l.strip() for l in entry.strip().splitlines()]
        if len(lines) < 3 or not lines[1].startswith("- Your "):
            continue
        kind = "note" if lines[1].startswith("- Your Note") else "highlight" if lines[1].startswith("- Your Highlight") else None
        body = "\n".join(l for l in lines[2:] if l)
        if not kind or not body:
            continue
        head = lines[0]
        title, authors = head, ""
        if head.endswith(")") and " (" in head:
            title, authors = head[:-1].rsplit(" (", 1)
        when = None
        loc = None
        for marker in ("Location ", "page "):
            if marker in lines[1]:
                digits = lines[1].split(marker, 1)[1].split("-")[0].split(" ")[0]
                loc = int(digits) if digits.isdigit() else None
                break
        if "Added on " in lines[1]:
            try:
                when = dt.datetime.strptime(lines[1].split("Added on ", 1)[1], "%A, %B %d, %Y %I:%M:%S %p").isoformat()
            except ValueError:
                pass
        key = (title, kind, body)
        if key in seen:
            continue
        seen.add(key)
        title = title.replace("_ ", ": ")
        book = books.setdefault(title, {"title": title, "authors": authors, "source": "kindle", "highlights": []})
        if kind == "note" and book["highlights"]:
            book["highlights"][-1]["note"] = body  # Kindle stores a note right after its highlight
        else:
            book["highlights"].append({"text": body, "datetime": when, "loc": loc, "source": "kindle"})
    return list(books.values())


def compute_highlights(user):
    folder = user.dav / HIGHLIGHTS_PATH
    books = []
    for path in folder.glob("*.json"):
        try:
            data = json.loads(path.read_text())
        except (ValueError, OSError):
            continue
        items = data.get("highlights") or []
        if isinstance(items, dict):  # an empty Lua table encodes as {}
            items = list(items.values())
        books.append({
            "title": data.get("title") or data.get("file") or "Untitled",
            "authors": (data.get("authors") or "").replace("\n", ", "),
            "md5": data.get("md5"),
            "source": "koreader",
            "highlights": [
                {"text": h.get("text"), "note": h.get("note"), "chapter": h.get("chapter"),
                 "datetime": (h.get("datetime") or "").replace(" ", "T") or None, "page": h.get("pageno"),
                 "loc": h.get("pageno"), "color": h.get("color"), "source": "koreader"}
                for h in items if h.get("text")
            ],
        })
    clippings = folder / "clippings.txt"
    if clippings.exists():
        books.extend(parse_clippings(clippings.read_text(errors="replace")))
    merged = {}
    for b in books:  # the same book can come from KOReader and from Kindle clippings
        key = title_key(b["title"])
        if key in merged:
            merged[key]["highlights"].extend(b["highlights"])
            merged[key]["authors"] = merged[key]["authors"] or b["authors"]
            merged[key]["md5"] = merged[key].get("md5") or b.get("md5")
        else:
            merged[key] = b
    books = [b for b in merged.values() if b["highlights"]]
    for b in books:
        b["highlights"].sort(key=lambda h: h.get("datetime") or "", reverse=True)
        b["latest"] = b["highlights"][0].get("datetime")
    books.sort(key=lambda b: b["latest"] or "", reverse=True)
    return {"count": sum(len(b["highlights"]) for b in books), "books": books}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("%s %s" % (self.command, fmt % args), flush=True)

    def send(self, code, body=b"", ctype="text/plain; charset=utf-8", headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, data, code=200):
        return self.send(code, json.dumps(data).encode(), "application/json", {"Cache-Control": "no-store"})

    def cookie_token(self):
        for part in self.headers.get("Cookie", "").split(";"):
            name, _, value = part.strip().partition("=")
            if name == COOKIE and value:
                return value
        return None

    def basic_user(self):
        """KOReader and scripts: username plus a device ("sync") password, never the account password."""
        header = self.headers.get("Authorization", "")
        if header.startswith("Basic "):
            try:
                name, _, pw = base64.b64decode(header[6:]).decode().partition(":")
            except ValueError:
                return None
            return AUTH.device_user("sync", pw, name)
        return None

    def widget_user(self):
        header = self.headers.get("Authorization", "")
        return AUTH.device_user("widget", header[7:]) if header.startswith("Bearer ") else None

    def secure_flag(self):
        # Plain http only when running locally; everywhere else the cookie is https-only.
        host = (self.headers.get("Host") or "").split(":")[0]
        return "" if host in ("localhost", "127.0.0.1") else "; Secure"

    def client_ip(self):
        return (self.headers.get("CF-Connecting-IP") or self.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                or self.client_address[0])

    def same_origin(self):
        """State-changing API calls must be JSON from this site (or a native client), not a cross-site form."""
        if not (self.headers.get("Content-Type") or "").startswith("application/json"):
            return False
        site = self.headers.get("Sec-Fetch-Site")
        if site and site not in ("same-origin", "none"):
            return False
        origin = self.headers.get("Origin")
        return not origin or urllib.parse.urlsplit(origin).netloc == self.headers.get("Host")

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 65536:
            raise AuthError("Request too large.")
        try:
            data = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            raise AuthError("Bad JSON.")
        if not isinstance(data, dict):
            raise AuthError("Bad JSON.")
        return data

    def handle_login(self):
        ip = self.client_ip()
        length = int(self.headers.get("Content-Length") or 0)
        form = urllib.parse.parse_qs(self.rfile.read(min(length, 4096)).decode(errors="replace"))
        if ip_locked(ip):
            return self.send(303, headers={"Location": "/login?e=locked"})
        user = AUTH.login(form.get("username", [""])[0], form.get("password", [""])[0])
        if not user:
            note_failure(ip)
            return self.send(303, headers={"Location": "/login?e=bad"})
        login_failures.pop(ip, None)
        token = AUTH.create_session(user, self.headers.get("User-Agent"), ip)
        cookie = "%s=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Lax%s" % (
            COOKIE, token, AUTH_SESSION_DAYS * 86400, self.secure_flag())
        return self.send(303, headers={"Location": "/account" if user.must_change_password else "/", "Set-Cookie": cookie})

    def drain(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

    def handle_one(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/healthz":
            return self.send(200, b"ok")
        if path == "/login":
            if self.command == "POST":
                return self.handle_login()
            self.drain()
            return self.send(200, LOGIN_HTML.encode(), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/logout":
            self.drain()
            token = self.cookie_token()
            if token:
                AUTH.end_session(token)
            return self.send(303, headers={"Location": "/login",
                                           "Set-Cookie": "%s=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax%s" % (COOKIE, self.secure_flag())})
        widget_user = path == "/api/widget" and self.widget_user()
        if widget_user:
            return self.send_json(compute_widget(widget_user))
        if path == "/dav" or path.startswith("/dav/"):
            ip = self.client_ip()
            if ip_locked(ip):
                self.drain()
                return self.send(429, b"too many failed logins")
            user = self.basic_user()
            if not user:
                if self.headers.get("Authorization"):
                    note_failure(ip)
                self.drain()
                return self.send(401, b"auth required", headers={"WWW-Authenticate": 'Basic realm="reading"'})
            return self.handle_dav(path, user)

        user, session_id = AUTH.session_user(self.cookie_token())
        if not user:
            user = self.basic_user()  # read-only API access with a device password, e.g. for scripts
            if not user:
                if self.headers.get("Authorization", "").startswith("Basic "):
                    note_failure(self.client_ip())
                self.drain()
                if path in ("/", "/account", "/admin"):
                    return self.send(303, headers={"Location": "/login"})
                return self.send(401, b"login required")
            if path.startswith("/api/account/") or path.startswith("/api/admin/") or path in ("/account", "/admin"):
                self.drain()
                return self.send(403, b"sign in on the web to manage the account")
        try:
            return self.route(path, user, session_id)
        except AuthError as e:
            return self.send_json({"error": str(e)}, 400)

    def route(self, path, user, session_id):
        method = self.command
        if method == "POST" and not self.same_origin():
            self.drain()
            return self.send_json({"error": "Cross-site request refused."}, 403)
        if path == "/account":
            self.drain()
            return self.send(200, ACCOUNT_HTML.encode(), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/api/me":
            self.drain()
            return self.send_json({"name": user.name, "is_admin": user.is_admin, "tz": user.tz_name,
                                   "must_change_password": user.must_change_password})
        if path.startswith("/api/account/"):
            return self.route_account(path[len("/api/account/"):], user, session_id)
        if user.must_change_password:
            self.drain()
            if path == "/":
                return self.send(303, headers={"Location": "/account"})
            return self.send_json({"error": "Choose a new password first."}, 403)
        if path == "/admin" or path.startswith("/api/admin/"):
            if not user.is_admin:
                self.drain()
                return self.send(303, headers={"Location": "/"}) if path == "/admin" else self.send_json({"error": "Admins only."}, 403)
            if path == "/admin":
                self.drain()
                return self.send(200, ADMIN_HTML.encode(), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
            return self.route_admin(path[len("/api/admin/"):], user)
        self.drain()
        if path == "/":
            return self.send(200, INDEX_HTML.encode(), "text/html; charset=utf-8", {"Cache-Control": "no-store"})
        if path == "/api/stats":
            return self.send_json(compute_stats(user))
        if path == "/api/library":
            return self.send_json(compute_library(user))
        if path.startswith("/cover/"):
            data = cover_for(path[len("/cover/"):], user)
            if not data:
                return self.send(404, b"no cover")
            return self.send(200, data, "image/jpeg", {"Cache-Control": "private, max-age=604800"})
        if path == "/api/highlights":
            return self.send_json(compute_highlights(user))
        if path == "/api/widget":
            return self.send_json(compute_widget(user))
        return self.send(404, b"not found")

    def route_account(self, sub, user, session_id):
        method = self.command
        if sub == "password" and method == "POST":
            body = self.read_json()
            AUTH.change_password(user, body.get("current", ""), body.get("new", ""), session_id)
            return self.send_json({"ok": True})
        if sub == "sessions" and method == "GET":
            return self.send_json({"sessions": AUTH.list_sessions(user, session_id)})
        if sub == "sessions/revoke" and method == "POST":
            body = self.read_json()
            if body.get("others"):
                AUTH.revoke_sessions(user, all_except=session_id or -1)
            else:
                AUTH.revoke_sessions(user, session_id=int(body.get("id") or 0))
            return self.send_json({"ok": True})
        if sub == "devices" and method == "GET":
            return self.send_json({"devices": AUTH.list_devices(user.id)})
        if sub == "devices" and method == "POST":
            body = self.read_json()
            return self.send_json({"secret": AUTH.create_device(user.id, "sync", body.get("label"))})
        if sub == "devices/revoke" and method == "POST":
            body = self.read_json()
            AUTH.revoke_device(user.id, int(body.get("id") or 0))
            return self.send_json({"ok": True})
        if sub == "widget-token" and method == "POST":
            # The iPhone app calls this once signed in, and hands the token to its widgets.
            body = self.read_json()
            client_id = str(body.get("client_id") or "")[:100] or None
            return self.send_json({"token": AUTH.create_device(user.id, "widget", body.get("label"), client_id),
                                   "name": user.name})
        self.drain()
        return self.send_json({"error": "Not found."}, 404)

    def route_admin(self, sub, user):
        method = self.command
        if sub == "users" and method == "GET":
            self.drain()
            return self.send_json({"users": AUTH.list_users(), "me": user.id})
        if sub == "users" and method == "POST":
            body = self.read_json()
            password = AUTH.create_user(body.get("name"), body.get("tz"), bool(body.get("is_admin")))
            return self.send_json({"password": password})
        if sub == "users/action" and method == "POST":
            body = self.read_json()
            return self.send_json(AUTH.admin_action(user, int(body.get("id") or 0), body.get("action"), body))
        self.drain()
        return self.send_json({"error": "Not found."}, 404)

    def handle_dav(self, path, user):
        target = dav_path(path, user)
        if target is None:
            self.drain()
            return self.send(403, b"forbidden")
        method = self.command

        if method == "OPTIONS":
            return self.send(200, headers={"DAV": "1", "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND"})

        if method == "PROPFIND":
            self.drain()
            if not target.exists():
                return self.send(404, b"not found")
            rel = target.relative_to(user.dav.resolve()).as_posix()
            base = "/dav/" if rel == "." else "/dav/" + rel + ("/" if target.is_dir() else "")
            parts = [propfind_entry(base, target)]
            if target.is_dir() and self.headers.get("Depth", "1") != "0":
                for child in sorted(target.iterdir()):
                    if child.name.startswith(".tmp"):
                        continue
                    parts.append(propfind_entry(base + child.name + ("/" if child.is_dir() else ""), child))
            body = ('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">%s</d:multistatus>'
                    % "".join(parts)).encode()
            return self.send(207, body, "application/xml; charset=utf-8")

        if method in ("GET", "HEAD"):
            if not target.is_file():
                return self.send(404, b"not found")
            return self.send(200, target.read_bytes(), "application/octet-stream",
                             {"ETag": etag_of(target), "Last-Modified": email.utils.formatdate(target.stat().st_mtime, usegmt=True)})

        if method == "PUT":
            length = int(self.headers.get("Content-Length") or -1)
            if length < 0 or length > MAX_UPLOAD:
                return self.send(411 if length < 0 else 413, b"bad length")
            if not target.parent.is_dir():
                self.rfile.read(length)
                return self.send(409, b"parent missing")
            if_match = self.headers.get("If-Match")
            if if_match and if_match.strip() != "*":
                current = etag_of(target) if target.is_file() else None
                if if_match.strip() != current:
                    self.rfile.read(length)
                    return self.send(412, b"etag mismatch")
            existed = target.exists()
            fd, tmp = tempfile.mkstemp(prefix=".tmp", dir=target.parent)
            with os.fdopen(fd, "wb") as f:
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(remaining, 1 << 16))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
            if remaining:
                os.unlink(tmp)
                return self.send(400, b"short body")
            os.replace(tmp, target)
            return self.send(204 if existed else 201, headers={"ETag": etag_of(target)})

        if method == "DELETE":
            self.drain()
            if target.is_file():
                target.unlink()
                return self.send(204)
            return self.send(404 if not target.exists() else 403, b"cannot delete")

        if method == "MKCOL":
            self.drain()
            if target.exists():
                return self.send(405, b"exists")
            if not target.parent.is_dir():
                return self.send(409, b"parent missing")
            target.mkdir()
            return self.send(201)

        self.drain()
        self.send(405, b"method not allowed")

    def __getattr__(self, name):
        if name.startswith("do_"):
            return self.handle_one
        raise AttributeError(name)


if __name__ == "__main__":
    print("listening on %d, data in %s, users: %s" % (PORT, ROOT, ", ".join(u["name"] for u in AUTH.list_users())), flush=True)
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
