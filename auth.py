"""Accounts, sessions and device passwords, kept in DATA_DIR/auth.sqlite3.

- users: one per reader. The password (web sign-in only) is hashed with PBKDF2-SHA256.
- sessions: web sign-ins. The cookie holds a random token; only its SHA-256 is stored.
- devices: per-device secrets, stored as SHA-256. Kind "sync" is a KOReader (WebDAV) password,
  kind "widget" is an iPhone's widget token. Each can be revoked on its own.

Secrets that the server generates are long and random, so a plain SHA-256 is enough for them and
keeps per-request checks cheap. Only the human-chosen account password gets the slow hash.
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import threading
import time
from pathlib import Path
from zoneinfo import ZoneInfo

PBKDF2_ITERATIONS = 600_000
SESSION_DAYS = 180
MIN_PASSWORD = 12
NAME_RE = re.compile(r"^[a-z][a-z0-9_]{1,31}$")
SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    is_admin INTEGER NOT NULL DEFAULT 0,
    disabled INTEGER NOT NULL DEFAULT 0,
    must_change_password INTEGER NOT NULL DEFAULT 0,
    tz TEXT,
    dav_dir TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    user_agent TEXT,
    ip TEXT
);
CREATE TABLE IF NOT EXISTS devices (
    id INTEGER PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('sync', 'widget')),
    label TEXT NOT NULL,
    secret_hash TEXT NOT NULL UNIQUE,
    client_id TEXT,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS devices_client ON devices(user_id, kind, client_id) WHERE client_id IS NOT NULL;
"""


class AuthError(Exception):
    """A request the caller should see as a 400 with this message."""


def sha256(text):
    return hashlib.sha256(text.encode()).hexdigest()


def hash_password(password):
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ITERATIONS)
    return "pbkdf2_sha256$%d$%s$%s" % (PBKDF2_ITERATIONS, salt.hex(), digest.hex())


def verify_password(password, stored):
    try:
        algo, iterations, salt, digest = stored.split("$")
    except ValueError:
        return False
    if algo != "pbkdf2_sha256":
        return False
    got = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(iterations))
    return hmac.compare_digest(got.hex(), digest)


# A real hash to check against when the username doesn't exist, so timing doesn't reveal names.
_DUMMY_HASH = hash_password(secrets.token_hex(8))


def new_device_secret():
    """Easy to type on an e-reader keyboard: four groups of four lowercase letters and digits (~80 bits)."""
    alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
    return "-".join("".join(secrets.choice(alphabet) for _ in range(4)) for _ in range(4))


def new_temp_password():
    return secrets.token_urlsafe(12)


def check_new_password(password):
    if len(password) < MIN_PASSWORD:
        raise AuthError("Use at least %d characters." % MIN_PASSWORD)


class User:
    def __init__(self, row, root, default_tz):
        self.id = row["id"]
        self.name = row["name"]
        self.is_admin = bool(row["is_admin"])
        self.must_change_password = bool(row["must_change_password"])
        self.tz = ZoneInfo(row["tz"]) if row["tz"] else default_tz
        self.tz_name = row["tz"]
        self.dav = root / row["dav_dir"]


class Auth:
    def __init__(self, root, default_tz):
        self.root = Path(root)
        self.default_tz = default_tz
        self.path = self.root / "auth.sqlite3"
        self.lock = threading.Lock()
        with self.db() as con:
            con.executescript(SCHEMA)

    def db(self):
        con = sqlite3.connect(self.path, timeout=10, isolation_level=None)
        con.row_factory = sqlite3.Row
        con.execute("PRAGMA foreign_keys = ON")
        return _Closing(con)

    def _user(self, row):
        user = User(row, self.root, self.default_tz)
        (user.dav / "koreader" / "highlights").mkdir(parents=True, exist_ok=True)
        return user

    # ---- setup -------------------------------------------------------------------------------

    def count_users(self):
        with self.db() as con:
            return con.execute("SELECT COUNT(*) FROM users").fetchone()[0]

    def import_from_env(self, env):
        """First start only: turn AUTH_USER/AUTH_PASSWORD/WIDGET_TOKEN and USERS into rows.
        Each imported password also becomes that account's KOReader device password, and each
        widget token an iPhone device, so devices set up before the table existed keep working."""
        if self.count_users():
            return []
        accounts = []
        if env.get("AUTH_PASSWORD"):
            accounts.append((env.get("AUTH_USER", "reader").lower(), env["AUTH_PASSWORD"], env.get("WIDGET_TOKEN", ""),
                             None, "dav", True))
        for name, cfg in json.loads(env.get("USERS") or "{}").items():
            accounts.append((name.lower(), cfg["password"], cfg.get("widget_token", ""), cfg.get("tz"),
                             "users/%s/dav" % name, False))
        now = int(time.time())
        with self.db() as con:
            con.execute("BEGIN")
            for name, password, widget, tz, dav_dir, admin in accounts:
                cur = con.execute(
                    "INSERT INTO users (name, password_hash, is_admin, tz, dav_dir, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (name, hash_password(password), int(admin), tz, dav_dir, now))
                con.execute("INSERT INTO devices (user_id, kind, label, secret_hash, created_at) VALUES (?, 'sync', ?, ?, ?)",
                            (cur.lastrowid, "E-reader (imported)", sha256(password), now))
                if widget:
                    con.execute("INSERT INTO devices (user_id, kind, label, secret_hash, created_at) VALUES (?, 'widget', ?, ?, ?)",
                                (cur.lastrowid, "iPhone widgets (imported)", sha256(widget), now))
            con.execute("COMMIT")
        return [a[0] for a in accounts]

    # ---- authentication ----------------------------------------------------------------------

    def login(self, name, password):
        """The User for a web sign-in, or None. Disabled accounts can't sign in."""
        with self.db() as con:
            row = con.execute("SELECT * FROM users WHERE name = ?", (name.strip().lower(),)).fetchone()
        ok = verify_password(password, row["password_hash"] if row else _DUMMY_HASH)
        if not row or not ok or row["disabled"]:
            return None
        return self._user(row)

    def create_session(self, user, user_agent, ip):
        token = secrets.token_urlsafe(32)
        now = int(time.time())
        with self.db() as con:
            con.execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
            con.execute("""INSERT INTO sessions (user_id, token_hash, created_at, last_seen_at, expires_at, user_agent, ip)
                           VALUES (?, ?, ?, ?, ?, ?, ?)""",
                        (user.id, sha256(token), now, now, now + SESSION_DAYS * 86400, (user_agent or "")[:200], ip))
        return token

    def session_user(self, token):
        """(User, session id) for a session cookie, or (None, None)."""
        if not token:
            return None, None
        now = int(time.time())
        with self.db() as con:
            row = con.execute("""SELECT u.*, s.id AS sid, s.last_seen_at FROM sessions s JOIN users u ON u.id = s.user_id
                                 WHERE s.token_hash = ? AND s.expires_at > ? AND u.disabled = 0""",
                              (sha256(token), now)).fetchone()
            if not row:
                return None, None
            if now - row["last_seen_at"] > 300:
                con.execute("UPDATE sessions SET last_seen_at = ? WHERE id = ?", (now, row["sid"]))
        return self._user(row), row["sid"]

    def end_session(self, token):
        with self.db() as con:
            con.execute("DELETE FROM sessions WHERE token_hash = ?", (sha256(token),))

    def device_user(self, kind, secret, name=None):
        """The User owning a device secret of this kind (and username, for sync), or None."""
        if not secret:
            return None
        with self.db() as con:
            row = con.execute("""SELECT u.*, d.id AS did, d.last_used_at FROM devices d JOIN users u ON u.id = d.user_id
                                 WHERE d.secret_hash = ? AND d.kind = ? AND u.disabled = 0""",
                              (sha256(secret), kind)).fetchone()
            if not row or (name is not None and not hmac.compare_digest(name.strip().lower().encode(), row["name"].encode())):
                return None
            now = int(time.time())
            if not row["last_used_at"] or now - row["last_used_at"] > 300:
                con.execute("UPDATE devices SET last_used_at = ? WHERE id = ?", (now, row["did"]))
        return self._user(row)

    # ---- the signed-in user's own account ---------------------------------------------------

    def change_password(self, user, current, new, keep_session_id):
        with self.db() as con:
            row = con.execute("SELECT password_hash FROM users WHERE id = ?", (user.id,)).fetchone()
            if not verify_password(current, row["password_hash"]):
                raise AuthError("Current password is wrong.")
            check_new_password(new)
            con.execute("BEGIN")
            con.execute("UPDATE users SET password_hash = ?, must_change_password = 0 WHERE id = ?", (hash_password(new), user.id))
            con.execute("DELETE FROM sessions WHERE user_id = ? AND id != ?", (user.id, keep_session_id or -1))
            con.execute("COMMIT")

    def list_sessions(self, user, current_id):
        with self.db() as con:
            rows = con.execute("""SELECT id, created_at, last_seen_at, user_agent, ip FROM sessions
                                  WHERE user_id = ? AND expires_at > ? ORDER BY last_seen_at DESC""",
                               (user.id, int(time.time()))).fetchall()
        return [dict(r, current=r["id"] == current_id) for r in rows]

    def revoke_sessions(self, user, session_id=None, all_except=None):
        with self.db() as con:
            if all_except is not None:
                con.execute("DELETE FROM sessions WHERE user_id = ? AND id != ?", (user.id, all_except))
            else:
                con.execute("DELETE FROM sessions WHERE user_id = ? AND id = ?", (user.id, session_id))

    def list_devices(self, user_id):
        with self.db() as con:
            rows = con.execute("""SELECT id, kind, label, created_at, last_used_at FROM devices
                                  WHERE user_id = ? ORDER BY kind, created_at""", (user_id,)).fetchall()
        return [dict(r) for r in rows]

    def create_device(self, user_id, kind, label, client_id=None):
        """Returns the new secret; it is only ever shown this once. A widget token for a client_id
        that already has one replaces it, so signing in again on the same phone doesn't pile up."""
        if kind not in ("sync", "widget"):
            raise AuthError("Unknown device kind.")
        label = (label or "").strip()[:60] or ("E-reader" if kind == "sync" else "iPhone")
        secret = new_device_secret() if kind == "sync" else secrets.token_urlsafe(32)
        with self.db() as con:
            con.execute("BEGIN")
            if client_id:
                con.execute("DELETE FROM devices WHERE user_id = ? AND kind = ? AND client_id = ?", (user_id, kind, client_id))
            con.execute("""INSERT INTO devices (user_id, kind, label, secret_hash, client_id, created_at)
                           VALUES (?, ?, ?, ?, ?, ?)""", (user_id, kind, label, sha256(secret), client_id, int(time.time())))
            con.execute("COMMIT")
        return secret

    def revoke_device(self, user_id, device_id):
        with self.db() as con:
            return con.execute("DELETE FROM devices WHERE user_id = ? AND id = ?", (user_id, device_id)).rowcount

    # ---- admin --------------------------------------------------------------------------------

    def list_users(self):
        with self.db() as con:
            rows = con.execute("""
                SELECT u.id, u.name, u.is_admin, u.disabled, u.must_change_password, u.tz, u.created_at,
                       MAX(COALESCE((SELECT MAX(last_seen_at) FROM sessions s WHERE s.user_id = u.id), 0),
                           COALESCE((SELECT MAX(last_used_at) FROM devices d WHERE d.user_id = u.id), 0)) AS last_active,
                       (SELECT COUNT(*) FROM devices d WHERE d.user_id = u.id) AS devices
                FROM users u ORDER BY u.created_at, u.id""").fetchall()
        return [dict(r) for r in rows]

    def create_user(self, name, tz=None, is_admin=False):
        """Returns the temporary password; the user must change it at first sign-in."""
        name = (name or "").strip().lower()
        if not NAME_RE.match(name):
            raise AuthError("Usernames are 2-32 lowercase letters, digits or _, starting with a letter.")
        if tz:
            try:
                ZoneInfo(tz)
            except (KeyError, ValueError):
                raise AuthError("Unknown time zone %r." % tz)
        temp = new_temp_password()
        with self.db() as con:
            if con.execute("SELECT 1 FROM users WHERE name = ?", (name,)).fetchone():
                raise AuthError("That username is taken.")
            dav_dir = "users/%s/dav" % name
            if (self.root / dav_dir).exists():  # a folder left by someone else; never hand it over
                raise AuthError("A data folder for %r already exists on the server." % name)
            con.execute("""INSERT INTO users (name, password_hash, is_admin, must_change_password, tz, dav_dir, created_at)
                           VALUES (?, ?, ?, 1, ?, ?, ?)""",
                        (name, hash_password(temp), int(is_admin), tz or None, dav_dir, int(time.time())))
        return temp

    def _admin_guard(self, con, actor, target_id, losing_admin):
        if target_id == actor.id:
            raise AuthError("You can't do that to your own account.")
        if losing_admin:
            row = con.execute("SELECT is_admin, disabled FROM users WHERE id = ?", (target_id,)).fetchone()
            others = con.execute("SELECT COUNT(*) FROM users WHERE is_admin = 1 AND disabled = 0 AND id != ?",
                                 (target_id,)).fetchone()[0]
            if row and row["is_admin"] and not row["disabled"] and others == 0:
                raise AuthError("There must be at least one admin.")

    def admin_action(self, actor, target_id, action, payload):
        """Returns a dict for the response (a new secret for reset/new_device)."""
        with self.db() as con:
            target = con.execute("SELECT * FROM users WHERE id = ?", (target_id,)).fetchone()
            if not target:
                raise AuthError("No such user.")
            if action == "reset_password":
                temp = new_temp_password()
                con.execute("BEGIN")
                con.execute("UPDATE users SET password_hash = ?, must_change_password = 1 WHERE id = ?",
                            (hash_password(temp), target_id))
                con.execute("DELETE FROM sessions WHERE user_id = ?", (target_id,))
                con.execute("COMMIT")
                return {"password": temp}
            if action in ("disable", "enable"):
                if action == "disable":
                    self._admin_guard(con, actor, target_id, losing_admin=True)
                con.execute("UPDATE users SET disabled = ? WHERE id = ?", (int(action == "disable"), target_id))
                if action == "disable":
                    con.execute("DELETE FROM sessions WHERE user_id = ?", (target_id,))
                return {}
            if action in ("make_admin", "remove_admin"):
                if action == "remove_admin":
                    self._admin_guard(con, actor, target_id, losing_admin=True)
                con.execute("UPDATE users SET is_admin = ? WHERE id = ?", (int(action == "make_admin"), target_id))
                return {}
            if action == "set_tz":
                tz = (payload.get("tz") or "").strip() or None
                if tz:
                    try:
                        ZoneInfo(tz)
                    except (KeyError, ValueError):
                        raise AuthError("Unknown time zone %r." % tz)
                con.execute("UPDATE users SET tz = ? WHERE id = ?", (tz, target_id))
                return {}
            if action == "delete":
                self._admin_guard(con, actor, target_id, losing_admin=True)
                con.execute("DELETE FROM users WHERE id = ?", (target_id,))
                # Keep the data, but out of reach of a future account with the same name.
                dav_dir = target["dav_dir"]
                src = self.root / (dav_dir.rsplit("/", 1)[0] if dav_dir.startswith("users/") else dav_dir)
                if src.exists():
                    dst = self.root / "deleted" / ("%s-%d" % (target["name"], int(time.time())))
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.move(str(src), str(dst))
                return {}
        if action == "new_device":
            return {"secret": self.create_device(target_id, "sync", payload.get("label"))}
        if action == "revoke_device":
            self.revoke_device(target_id, int(payload.get("device_id") or 0))
            return {}
        if action == "devices":
            return {"devices": self.list_devices(target_id)}
        raise AuthError("Unknown action.")


class _Closing:
    def __init__(self, con):
        self.con = con

    def __enter__(self):
        return self.con

    def __exit__(self, *exc):
        if exc[0] is not None and self.con.in_transaction:
            self.con.execute("ROLLBACK")
        self.con.close()
