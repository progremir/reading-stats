#!/usr/bin/env python3
"""Fill a DATA_DIR with six months of made-up reading of public-domain books.

For trying the server locally and for screenshots:

    scripts/demo_data.py ./demo-data
    AUTH_PASSWORD=demo-password-123 DATA_DIR=./demo-data PORT=8080 python3 server.py

Covers come from Project Gutenberg; pass --no-covers to skip downloading them.
"""

import argparse
import datetime as dt
import hashlib
import json
import random
import sqlite3
import sys
import urllib.request
from pathlib import Path

# title, author, pages, Gutenberg id, highlights as (chapter, text, note)
BOOKS = [
    ("Walden", "Henry David Thoreau", 352, 205, [
        ("Economy", "The mass of men lead lives of quiet desperation.", None),
        ("Where I Lived, and What I Lived For",
         "I went to the woods because I wished to live deliberately, to front only the essential facts of life, "
         "and see if I could not learn what it had to teach, and not, when I came to die, discover that I had not lived.",
         "The whole book in one sentence."),
        ("Where I Lived, and What I Lived For", "Our life is frittered away by detail. Simplify, simplify.", None),
    ]),
    ("Meditations", "Marcus Aurelius", 254, 2680, [
        ("Book II", "Begin the morning by saying to thyself, I shall meet with the busy-body, the ungrateful, "
                    "arrogant, deceitful, envious, unsocial.", "Morning routine"),
        ("Book IV", "The universe is transformation: life is opinion.", None),
        ("Book IV", "Do not act as if thou wert going to live ten thousand years. Death hangs over thee. "
                    "While thou livest, while it is in thy power, be good.", None),
        ("Book VII", "Look within. Within is the fountain of good, and it will ever bubble up, if thou wilt ever dig.", None),
    ]),
    ("Moby-Dick", "Herman Melville", 720, 2701, [
        ("Loomings", "Call me Ishmael.", None),
        ("Biographical", "It is not down on any map; true places never are.", None),
        ("First Night-Watch", "I know not all that may be coming, but be it what it will, I'll go to it laughing.", None),
    ]),
    ("Pride and Prejudice", "Jane Austen", 432, 1342, [
        ("Chapter 1", "It is a truth universally acknowledged, that a single man in possession of a good fortune, "
                      "must be in want of a wife.", None),
        ("Chapter 11", "I declare after all there is no enjoyment like reading!", "Same, Caroline."),
    ]),
    ("Frankenstein", "Mary Wollstonecraft Shelley", 280, 84, [
        ("Chapter 20", "Beware; for I am fearless, and therefore powerful.", None),
        ("Chapter 23", "Nothing is so painful to the human mind as a great and sudden change.", None),
    ]),
    ("The Art of War", "Sun Tzu", 96, 132, [
        ("Laying Plans", "All warfare is based on deception.", None),
        ("Attack by Stratagem", "Supreme excellence consists in breaking the enemy's resistance without fighting.", None),
    ]),
    ("Siddhartha", "Hermann Hesse", 152, 2500, [
        ("Govinda", "Knowledge can be conveyed, but not wisdom.", None),
    ]),
    ("The Odyssey", "Homer", 416, 1727, []),
]
WORDS = [("Pride and Prejudice", "Jane Austen", w) for w in ("obsequious", "condescension", "felicity")] + \
        [("Walden", "Henry David Thoreau", w) for w in ("frittered", "deliberately")] + \
        [("Moby-Dick", "Herman Melville", w) for w in ("leviathan", "taffrail", "hypos")]

# Order books were read in, and how far each got.
PLAN = [("The Art of War", 1.0), ("Frankenstein", 1.0), ("Pride and Prejudice", 1.0), ("Meditations", 1.0),
        ("Moby-Dick", 0.34), ("The Odyssey", 0.21), ("Siddhartha", 0.12), ("Walden", 0.62)]


def title_key(title):
    return " ".join(title.casefold().replace("_", ":").split())


def book_id(title):
    return hashlib.sha1(title_key(title).encode()).hexdigest()[:12]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("data_dir")
    ap.add_argument("--no-covers", action="store_true")
    args = ap.parse_args()

    rng = random.Random(7)
    root = Path(args.data_dir)
    ko = root / "dav" / "koreader"
    (ko / "highlights").mkdir(parents=True, exist_ok=True)
    (root / "covers").mkdir(parents=True, exist_ok=True)
    db_path = ko / "statistics.sqlite3"
    db_path.unlink(missing_ok=True)

    con = sqlite3.connect(db_path)
    con.executescript("""
        CREATE TABLE book (id integer PRIMARY KEY autoincrement, title text, authors text, notes integer,
            last_open integer, highlights integer, pages integer, series text, language text, md5 text,
            total_read_time integer, total_read_pages integer);
        CREATE TABLE page_stat_data (id_book integer, page integer NOT NULL DEFAULT 0,
            start_time integer NOT NULL DEFAULT 0, duration integer NOT NULL DEFAULT 0,
            total_pages integer NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
    """)
    info = {b[0]: b for b in BOOKS}
    ids = {}
    for i, (title, author, pages, _, _) in enumerate(BOOKS, 1):
        md5 = hashlib.md5(title.encode()).hexdigest()
        ids[title] = (i, md5)
        con.execute("INSERT INTO book (id, title, authors, pages, md5) VALUES (?, ?, ?, ?, ?)",
                    (i, title, author, pages, md5))

    # Walk 182 days, reading most of them (the last 12 in a row), working through PLAN in order:
    # each reading day turns its share of all the pages to be read.
    today = dt.date.today()
    targets = [(t, int(info[t][2] * share)) for t, share in PLAN]
    days = [today - dt.timedelta(days=back) for back in range(181, -1, -1)
            if back < 12 or rng.random() >= 0.3]
    queue = [(title, page) for title, upto in targets for page in range(1, upto + 1)]
    last_open = {}
    for n, day in enumerate(days):
        todays = queue[len(queue) * n // len(days):len(queue) * (n + 1) // len(days)]
        t = dt.datetime.combine(day, dt.time(21, rng.randint(0, 40))).timestamp()
        for title, page in todays:
            bid, _ = ids[title]
            dur = rng.randint(70, 260)
            con.execute("INSERT OR IGNORE INTO page_stat_data VALUES (?, ?, ?, ?, ?)",
                        (bid, page, int(t), dur, info[title][2]))
            last_open[title] = int(t)
            t += dur
    for title, ts in last_open.items():
        con.execute("UPDATE book SET last_open = ? WHERE id = ?", (ts, ids[title][0]))
    con.commit()
    con.close()

    # Highlights as the KOReader plugin uploads them, dated while each book was being read.
    for title, author, pages, _, highlights in BOOKS:
        if not highlights or title not in last_open:
            continue
        _, md5 = ids[title]
        end = dt.datetime.fromtimestamp(last_open[title])
        items = []
        for n, (chapter, text, note) in enumerate(highlights):
            when = end - dt.timedelta(days=(len(highlights) - n) * 3, hours=n)
            items.append({"text": text, "note": note, "chapter": chapter, "pageno": 10 + n * pages // 8,
                          "datetime": when.strftime("%Y-%m-%d %H:%M:%S"), "color": "yellow", "drawer": "lighten"})
        (ko / "highlights" / (md5 + ".json")).write_text(json.dumps(
            {"md5": md5, "title": title, "authors": author, "pages": pages, "highlights": items}))

    # A few dictionary lookups from the stock Kindle reader's clippings file.
    base = dt.datetime.combine(today - dt.timedelta(days=200), dt.time(21, 0))
    clips = "".join("﻿%s (%s)\n- Your Highlight on Location %d-%d | Added on %s\n\n%s\n==========\n"
                    % (t, a, 100 + i * 37, 100 + i * 37, (base + dt.timedelta(minutes=i)).strftime("%A, %B %d, %Y %I:%M:%S %p"), w)
                    for i, (t, a, w) in enumerate(WORDS))
    (ko / "highlights" / "clippings.txt").write_text(clips)

    if not args.no_covers:
        for title, _, _, gid, _ in BOOKS:
            dest = root / "covers" / (book_id(title) + ".jpg")
            url = "https://www.gutenberg.org/cache/epub/%d/pg%d.cover.medium.jpg" % (gid, gid)
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "reading-stats demo"})
                dest.write_bytes(urllib.request.urlopen(req, timeout=20).read())
            except OSError as e:
                print("no cover for %s: %s" % (title, e), file=sys.stderr)

    print("Demo data written to", root)


if __name__ == "__main__":
    main()
