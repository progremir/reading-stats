#!/usr/bin/env python3
"""Point a KOReader install (mounted over USB) at a Readstreak server.

Run it while the e-reader is mounted as a drive and KOReader is NOT running
(on a Kindle, the drive only mounts once KOReader has exited). It:

  * backs up the files it touches to <koreader>/settings/reading-stats-backup-<time>/
  * sets the WebDAV server for Reading statistics cloud sync
  * adds the same server to Cloud storage (so it shows in KOReader's menus)
  * runs a "Sync reading stats" profile whenever a book is closed
  * installs the highlightsync plugin from this repo
  * optionally sets the home folder KOReader opens to, and SSH key login

Usage:
  scripts/configure_koreader.py --device /Volumes/Kindle --server https://read.example.com \\
      --user reader --password 'abcd-efgh-jkmn-pqrs' [--home-dir /mnt/us/documents/Books] [--ssh-key ~/.ssh/id_ed25519.pub]

--password is an e-reader (device) password from the account page, not the account password:
it is stored on the device in plain text.
"""

import argparse
import re
import shutil
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PLUGIN = REPO / "koreader" / "highlightsync.koplugin"
PROFILE = "Sync reading stats"


def lua(value, indent):
    """Serialize a Python value the way KOReader's LuaSettings writes it."""
    pad = " " * indent
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\\n") + '"'
    if isinstance(value, dict):
        if not value:
            return "{}"
        inner = "".join('%s    ["%s"] = %s,\n' % (pad, k, lua(v, indent + 4)) for k, v in sorted(value.items()))
        return "{\n" + inner + pad + "}"
    raise TypeError(value)


def entry_span(lines, key, indent, start=0, end=None):
    """Find a `["key"] = ...,` entry written at `indent` spaces; returns (first, last) line indexes."""
    end = len(lines) if end is None else end
    head = " " * indent + '["%s"] = ' % key
    for i in range(start, end):
        if lines[i].startswith(head):
            if lines[i].rstrip().endswith("{"):  # a table: runs to its closing brace at the same indent
                close = " " * indent + "},"
                j = i + 1
                while j < end and lines[j].rstrip() != close:
                    j += 1
                return i, j
            j = i
            while lines[j].endswith("\\") and j + 1 < end:  # multi-line string
                j += 1
            return i, j
    return None


def set_entry(lines, key, value, indent=4, start=0, end=None):
    """Replace or insert a key inside the table whose entries are at `indent`."""
    text = (" " * indent + '["%s"] = %s,' % (key, lua(value, indent))).split("\n")
    span = entry_span(lines, key, indent, start, end)
    if span:
        lines[span[0]:span[1] + 1] = text
        return
    # Insert in key order like KOReader does (it re-sorts on save anyway).
    end = len(lines) if end is None else end
    pos = None
    for i in range(start, end):
        m = re.match(r'^ {%d}\["([^"]+)"\] = ' % indent, lines[i])
        if m and m.group(1) > key:
            pos = i
            break
    if pos is None:
        pos = end - 1 if end == len(lines) else end  # before the table's closing brace
        while pos > start and not re.match(r"^ {%d}\}" % (indent - 4), lines[pos]):
            pos -= 1
    lines[pos:pos] = text


def balanced(text):
    depth, in_str, esc = 0, False, False
    for ch in text:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0 and not in_str


def edit_settings(path, server, args):
    lines = path.read_text().split("\n")

    # Reading statistics: enable and set the sync server, keeping the user's other stats settings.
    span = entry_span(lines, "statistics", 4)
    if span and lines[span[0]].rstrip().endswith("{"):
        set_entry(lines, "sync_server", server, indent=8, start=span[0] + 1, end=span[1] + 1)
        span = entry_span(lines, "statistics", 4)
        set_entry(lines, "is_enabled", True, indent=8, start=span[0] + 1, end=span[1] + 1)
    else:
        set_entry(lines, "statistics", {"is_enabled": True, "sync_server": server})

    set_entry(lines, "profiles_autoexec", {"CloseDocument": {PROFILE: True}})
    if args.home_dir:
        set_entry(lines, "home_dir", args.home_dir)
        set_entry(lines, "lock_home_folder", True)
        set_entry(lines, "start_with", "filemanager")
    if args.ssh_key:
        set_entry(lines, "SSH_autostart", True)
        set_entry(lines, "SSH_key_only_auth", True)

    text = "\n".join(lines)
    if not balanced(text):
        sys.exit("refusing to write %s: result is not a balanced Lua table" % path)
    path.write_text(text)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", required=True, help="mount point of the e-reader, e.g. /Volumes/Kindle")
    ap.add_argument("--server", required=True, help="Readstreak base URL, e.g. https://read.example.com")
    ap.add_argument("--user", default="reader", help="the reader's username on the server")
    ap.add_argument("--password", required=True, help="an e-reader (device) password from the account page")
    ap.add_argument("--home-dir", help="folder KOReader opens to, as the device sees it (e.g. /mnt/us/documents/Books)")
    ap.add_argument("--ssh-key", help="public key to authorize for KOReader's SSH server (port 2222)")
    args = ap.parse_args()

    ko = Path(args.device) / "koreader"
    settings = ko / "settings.reader.lua"
    if not settings.exists():
        sys.exit("%s not found: install KOReader and open it once, then exit it and mount the device again" % settings)

    server = {
        "type": "webdav",
        "name": "Reading stats",
        "address": args.server.rstrip("/") + "/dav",
        "username": args.user,
        "password": args.password,
        "url": "/koreader",
    }

    backup = ko / "settings" / ("reading-stats-backup-" + time.strftime("%Y%m%d-%H%M%S"))
    backup.mkdir(parents=True, exist_ok=True)
    for f in (settings, ko / "settings" / "cloudstorage.lua", ko / "settings" / "profiles.lua"):
        if f.exists():
            shutil.copy2(f, backup / f.name)

    edit_settings(settings, server, args)

    (ko / "settings" / "cloudstorage.lua").write_text(
        "-- ./settings/cloudstorage.lua\nreturn " + lua({"cs_servers": {}}, 0).replace(
            '["cs_servers"] = {}', '["cs_servers"] = {\n        [1] = %s,\n    }' % lua(server, 8)) + "\n")

    profiles_path = ko / "settings" / "profiles.lua"
    profiles_lines = profiles_path.read_text().split("\n") if profiles_path.exists() else ["return {", "}"]
    if not any(l.startswith("return {") for l in profiles_lines):
        profiles_lines = ["return {", "}"]
    if profiles_lines[-1] == "":
        profiles_lines.pop()
    if profiles_lines[-1].strip() == "return {}" or (len(profiles_lines) == 1):
        profiles_lines = ["return {", "}"]
    set_entry(profiles_lines, PROFILE, {"settings": {"name": PROFILE}, "stats_sync": True})
    profiles_path.write_text("\n".join(profiles_lines) + "\n")

    dest = ko / "plugins" / PLUGIN.name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(PLUGIN, dest)

    if args.ssh_key:
        (ko / "settings" / "SSH").mkdir(exist_ok=True)
        shutil.copy(Path(args.ssh_key).expanduser(), ko / "settings" / "SSH" / "authorized_keys")

    print("KOReader configured. Backup of the previous settings:", backup)


if __name__ == "__main__":
    main()
