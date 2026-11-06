"""Export a copied library's articles and event membership for the wire identity evaluation."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlsplit

FEED_LIMIT = 16 * 1024 * 1024


def export(database: Path, output: Path) -> None:
    """Read only the supplied copy and create a new private input file, which holds article text."""
    output = output.expanduser().resolve()
    if output.exists():
        raise SystemExit(f"Refusing to overwrite an existing input file: {output}")
    connection = sqlite3.connect("file:" + quote(str(database.resolve())) + "?mode=ro", uri=True)
    try:
        columns = {row[1] for row in connection.execute("PRAGMA table_info(articles)")}
        author = "a.author" if "author" in columns else "NULL"
        rows = connection.execute(
            "SELECT a.id, coalesce(e.merged_into, m.event_id), a.source, a.title, coalesce(a.description, ''), "
            f"a.content, a.published_at, a.created_at, a.canonical_url, {author} FROM articles a "
            "LEFT JOIN event_members m ON m.article_id = a.id LEFT JOIN events e ON e.id = m.event_id ORDER BY a.id"
        ).fetchall()
    finally:
        connection.close()
    fields = (
        "articleID", "eventID", "publisher", "title", "description", "content", "publishedAt", "fetchedAt",
        "canonicalURL", "author",
    )
    descriptor = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump({"basis": "copied_library", "articles": [dict(zip(fields, row)) for row in rows]}, stream)
        stream.write("\n")


def fetch_feeds(database: Path, directory: Path) -> None:
    """Fetch the copy's own subscribed feeds once into `directory`; a feed that fails is reported and skipped."""
    connection = sqlite3.connect("file:" + quote(str(database.resolve())) + "?mode=ro", uri=True)
    try:
        urls = [row[0] for row in connection.execute("SELECT url FROM feeds ORDER BY url")]
    finally:
        connection.close()
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    failed = 0
    for index, url in enumerate(urls):
        if urlsplit(url).scheme not in ("http", "https"):
            failed += 1
            continue
        request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                (directory / f"{index}.xml").write_bytes(response.read(FEED_LIMIT))
        except OSError:
            failed += 1
    print(f"Fetched {len(urls) - failed} of {len(urls)} feeds")


def main() -> None:
    """Parse library copy and output paths."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--feeds-directory", type=Path)
    args = parser.parse_args()
    export(args.database, args.output)
    if args.feeds_directory:
        fetch_feeds(args.database, args.feeds_directory)


if __name__ == "__main__":
    main()
