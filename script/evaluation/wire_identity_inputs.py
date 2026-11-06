"""Export a copied library's articles and event membership for the wire identity evaluation."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path
from urllib.parse import quote


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


def main() -> None:
    """Parse library copy and output paths."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    export(args.database, args.output)


if __name__ == "__main__":
    main()
