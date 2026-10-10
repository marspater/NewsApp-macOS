#!/usr/bin/env python3
"""Validate the catalog review manifest and verify alternative source recommendations."""
import json
import pathlib
import re
import sys
from datetime import datetime

ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "Tests/Fixtures/catalog-review/catalog-review-v1.json"
FEED_CATALOG_SWIFT = ROOT / "Sources/Models/FeedCatalog.swift"

VALID_STATUSES = {"active", "advisory", "retired"}
VALID_REASONS = {
    "technical_deterioration",
    "reader_inaccessible",
    "paywall_introduced",
    "ownership_change",
    "syndication_shift",
    "standard_update",
}
VALID_UNCERTAINTIES = {"known", "provisional", "unknown"}
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_catalog_feed_ids(swift_path):
    """Extract catalog feed IDs defined in FeedCatalog.swift."""
    text = swift_path.read_text(encoding="utf-8")
    feed_ids = set(re.findall(r'id:\s*"([^"]+)"', text))
    require(len(feed_ids) >= 30, f"Expected at least 30 catalog feeds, found {len(feed_ids)}")
    return feed_ids


def validate_manifest(manifest, catalog_feed_ids):
    require(isinstance(manifest, dict), "Manifest must be a JSON object")
    require(manifest.get("version") == 1, "Manifest version must be 1")
    require(bool(manifest.get("reviewer")), "Manifest must specify a reviewer")

    reviewed_on = manifest.get("reviewedOn")
    require(isinstance(reviewed_on, str) and DATE_PATTERN.match(reviewed_on), "Invalid reviewedOn date format")
    try:
        datetime.strptime(reviewed_on, "%Y-%m-%d")
    except ValueError as err:
        raise ValueError(f"Invalid reviewedOn calendar date: {reviewed_on}") from err

    feeds = manifest.get("feeds")
    require(isinstance(feeds, list) and len(feeds) > 0, "Manifest must include at least one feed review")

    seen_ids = set()
    seen_urls = set()

    for item in feeds:
        feed_id = item.get("id")
        url = item.get("url")
        status = item.get("status")

        require(feed_id and isinstance(feed_id, str), "Feed must have a valid string id")
        require(feed_id not in seen_ids, f"Duplicate feed id in review manifest: {feed_id}")
        seen_ids.add(feed_id)

        require(url and isinstance(url, str) and url.startswith("https://"), f"Invalid HTTPS URL for feed {feed_id}")
        require(url not in seen_urls, f"Duplicate feed URL in review manifest: {url}")
        seen_urls.add(url)

        require(status in VALID_STATUSES, f"Invalid status '{status}' for feed {feed_id}")

        advisory = item.get("advisory")
        if status in ("advisory", "retired"):
            require(isinstance(advisory, dict), f"Feed {feed_id} with status '{status}' requires an advisory object")

        if advisory is not None:
            adv_date = advisory.get("date")
            require(isinstance(adv_date, str) and DATE_PATTERN.match(adv_date), f"Invalid advisory date for {feed_id}")
            try:
                datetime.strptime(adv_date, "%Y-%m-%d")
            except ValueError as err:
                raise ValueError(f"Invalid advisory calendar date: {adv_date}") from err

            reason = advisory.get("reason")
            require(reason in VALID_REASONS, f"Invalid advisory reason '{reason}' for feed {feed_id}")

            summary = advisory.get("summary")
            require(isinstance(summary, str) and len(summary.strip()) >= 10, f"Advisory summary too short for {feed_id}")

            uncertainty = advisory.get("uncertainty")
            require(uncertainty in VALID_UNCERTAINTIES, f"Invalid uncertainty '{uncertainty}' for feed {feed_id}")

            links = advisory.get("evidenceLinks")
            require(isinstance(links, list) and len(links) >= 1, f"Advisory must provide evidence links for {feed_id}")
            for link in links:
                require(
                    isinstance(link, str) and link.startswith("https://"),
                    f"Evidence link must be HTTPS for feed {feed_id}: {link}",
                )

            alt_ids = advisory.get("suggestedAlternativeFeedIDs")
            require(isinstance(alt_ids, list), f"suggestedAlternativeFeedIDs must be a list for feed {feed_id}")
            for alt_id in alt_ids:
                require(
                    alt_id in catalog_feed_ids,
                    f"Alternative feed id '{alt_id}' for '{feed_id}' does not exist in FeedCatalog",
                )
                require(alt_id != feed_id, f"Feed {feed_id} cannot suggest itself as an alternative")

    return seen_ids


def main():
    manifest_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_MANIFEST
    require(manifest_path.exists(), f"Review manifest not found at {manifest_path}")

    catalog_ids = parse_catalog_feed_ids(FEED_CATALOG_SWIFT)
    raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    reviewed_ids = validate_manifest(raw, catalog_ids)

    print(f"Catalog review validation: OK ({len(reviewed_ids)} feed reviews validated against {len(catalog_ids)} catalog feeds)")


if __name__ == "__main__":
    main()
