#!/usr/bin/env python3
"""Validate the catalog review manifest against FeedCatalog.swift. Runs a self-check on malformed manifests first."""
import copy
import json
import pathlib
import re
from datetime import date
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "Tests/Fixtures/catalog-review/catalog-review-v1.json"
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
FEED_PATTERN = re.compile(r'CatalogFeed\(\s*id:\s*"([^"]+)".*?url:\s*"([^"]+)",\s*language:\s*"([^"]+)"', re.S)
ADVISORY_PATTERN = re.compile(r'"([^"]+)":\s*FeedAdvisory\(\s*date:\s*"([^"]+)"')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse_catalog(text):
    """Return the catalog URL by feed id, the offered feed ids and the app's advisory date by URL."""
    feeds = {feed_id: (url, language) for feed_id, url, language in FEED_PATTERN.findall(text)}
    require(len(feeds) >= 30, f"Expected at least 30 catalog feeds, found {len(feeds)}")
    supported = re.search(r"supportedLanguages[^=]*=\s*\[([^\]]*)\]", text)
    require(supported is not None, "FeedCatalog.supportedLanguages not found")
    languages = set(re.findall(r'"([^"]+)"', supported.group(1)))
    offered = {feed_id for feed_id, (_, language) in feeds.items() if language in languages}
    advisories = dict(ADVISORY_PATTERN.findall(text))
    return {feed_id: url for feed_id, (url, _) in feeds.items()}, offered, advisories


def require_date(value, label):
    require(isinstance(value, str) and DATE_PATTERN.match(value), f"Invalid {label} date format: {value}")
    try:
        date.fromisoformat(value)
    except ValueError as err:
        raise ValueError(f"Invalid {label} calendar date: {value}") from err


def require_normalized_https(url, label):
    """Mirror AppSettings.normalizeFeedURL: HTTPS, lowercase host, no trailing slash."""
    require(isinstance(url, str), f"{label} must be a string")
    parts = urlsplit(url)
    require(
        parts.scheme == "https" and parts.hostname and parts.netloc == parts.netloc.lower()
        and not parts.path.endswith("/") and not parts.fragment,
        f"{label} is not a normalized HTTPS URL: {url}",
    )


def validate_advisory(advisory, feed_id, offered):
    require(isinstance(advisory, dict), f"Feed {feed_id} advisory must be an object")
    require_date(advisory.get("date"), f"advisory ({feed_id})")
    require(advisory.get("reason") in VALID_REASONS, f"Invalid advisory reason for feed {feed_id}")
    summary = advisory.get("summary")
    require(isinstance(summary, str) and len(summary.strip()) >= 10, f"Advisory summary too short for {feed_id}")
    require(advisory.get("uncertainty") in VALID_UNCERTAINTIES, f"Invalid uncertainty for feed {feed_id}")

    links = advisory.get("evidenceLinks")
    require(isinstance(links, list) and links, f"Advisory must provide evidence links for {feed_id}")
    for link in links:
        require_normalized_https(link, f"Evidence link for {feed_id}")

    alt_ids = advisory.get("suggestedAlternativeFeedIDs")
    require(isinstance(alt_ids, list), f"suggestedAlternativeFeedIDs must be a list for feed {feed_id}")
    for alt_id in alt_ids:
        require(alt_id != feed_id, f"Feed {feed_id} cannot suggest itself as an alternative")
        require(alt_id in offered, f"Alternative '{alt_id}' for '{feed_id}' is not an offered catalog feed")


def validate_entry(item, catalog, offered):
    require(isinstance(item, dict), "Feed review must be an object")
    feed_id, url, status = item.get("id"), item.get("url"), item.get("status")
    require(isinstance(feed_id, str) and feed_id, "Feed must have a valid string id")
    require(status in VALID_STATUSES, f"Invalid status '{status}' for feed {feed_id}")
    require_normalized_https(url, f"URL for feed {feed_id}")
    if feed_id in catalog:
        require(catalog[feed_id] == url, f"URL for feed {feed_id} does not match FeedCatalog: {url}")
    else:
        require(status == "retired", f"Feed {feed_id} is not in FeedCatalog, so it must be retired")

    advisory = item.get("advisory")
    require(status == "active" or advisory is not None, f"Feed {feed_id} with status '{status}' requires an advisory")
    if advisory is not None:
        validate_advisory(advisory, feed_id, offered)


def validate_manifest(manifest, catalog, offered, app_advisories):
    """Validate the manifest and require the app's advisories to match its dated advisories exactly."""
    require(isinstance(manifest, dict), "Manifest must be a JSON object")
    require(manifest.get("version") == 1, "Manifest version must be 1")
    require(bool(manifest.get("reviewer")), "Manifest must specify a reviewer")
    require_date(manifest.get("reviewedOn"), "reviewedOn")

    feeds = manifest.get("feeds")
    require(isinstance(feeds, list) and feeds, "Manifest must include at least one feed review")
    for item in feeds:
        validate_entry(item, catalog, offered)
    ids = [item["id"] for item in feeds]
    urls = [item["url"] for item in feeds]
    require(len(set(ids)) == len(ids), "Duplicate feed id in review manifest")
    require(len(set(urls)) == len(urls), "Duplicate feed URL in review manifest")

    dated = {item["url"]: item["advisory"]["date"] for item in feeds if item.get("advisory")}
    require(dated == app_advisories, f"FeedCatalog.advisoriesByURL {app_advisories} does not match manifest {dated}")
    return ids


def first(manifest):
    return manifest["feeds"][0]


def self_check(manifest, catalog, offered, app_advisories):
    def rejected(mutate, message):
        broken = copy.deepcopy(manifest)
        mutate(broken)
        try:
            validate_manifest(broken, catalog, offered, app_advisories)
        except ValueError:
            return
        raise ValueError(f"Self-check: {message}")

    parked = next(feed_id for feed_id in catalog if feed_id not in offered)
    rejected(lambda m: m.update(reviewedOn="2026-02-30"), "an impossible date was accepted")
    rejected(lambda m: first(m)["advisory"].update(date="2026-1-08"), "a malformed advisory date was accepted")
    rejected(lambda m: first(m).update(url=first(m)["url"] + "/"), "an unnormalized URL was accepted")
    rejected(lambda m: first(m).update(url=first(m)["url"].replace("https:", "http:")), "an HTTP URL was accepted")
    rejected(lambda m: first(m).update(id="unknown-feed"), "an unknown feed that is not retired was accepted")
    rejected(lambda m: first(m).update(status="paused"), "an unknown status was accepted")
    rejected(lambda m: first(m).update(advisory=None), "an advisory status without details was accepted")
    rejected(lambda m: first(m)["advisory"].update(reason="biased"), "an unknown reason was accepted")
    rejected(lambda m: first(m)["advisory"].update(evidenceLinks=[]), "an advisory without evidence was accepted")
    rejected(lambda m: first(m)["advisory"].update(suggestedAlternativeFeedIDs=[parked]), "a parked alternative was accepted")
    rejected(lambda m: first(m)["advisory"].update(suggestedAlternativeFeedIDs=[first(m)["id"]]), "a self-alternative was accepted")
    rejected(lambda m: m["feeds"].append(copy.deepcopy(first(m))), "a duplicate feed was accepted")
    rejected(lambda m: first(m)["advisory"].update(date="2026-10-09"), "an advisory out of sync with the app was accepted")


def main():
    catalog, offered, app_advisories = parse_catalog(FEED_CATALOG_SWIFT.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    self_check(manifest, catalog, offered, app_advisories)
    reviewed = validate_manifest(manifest, catalog, offered, app_advisories)
    print(f"Catalog review validation: OK ({len(reviewed)} feed reviews against {len(catalog)} catalog feeds)")


if __name__ == "__main__":
    main()
