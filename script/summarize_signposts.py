"""Summarizes an `xctrace export` of the os-signpost-interval table (#577).

Writes <prefix>.json and <prefix>.md: per subsystem category and interval name, count, median and p90 duration in ms.
Usage: summarize_signposts.py signposts.xml summary [--meta key=value ...]
"""

import json
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import defaultdict


def rows(path):
    """Yields each row as {mnemonic: element}, resolving xctrace's id/ref de-duplication."""
    root = ET.parse(path).getroot()
    node = root.find(".//node")
    if node is None:
        return
    columns = [col.findtext("mnemonic") for col in node.find("schema").findall("col")]
    by_id = {}
    for element in node.iter():
        if "id" in element.attrib:
            by_id[element.attrib["id"]] = element
    for row in node.findall("row"):
        cells = {}
        for name, cell in zip(columns, row):
            cells[name] = by_id.get(cell.attrib["ref"], cell) if "ref" in cell.attrib else cell
        yield cells


def text(element):
    return element.text if element.text is not None else element.attrib.get("fmt", "")


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def summarize(path):
    groups = defaultdict(list)
    for cells in rows(path):
        if cells.get("subsystem") is None or text(cells["subsystem"]) != "com.marspater.news":
            continue
        key = (text(cells["category"]), text(cells["name"]))
        groups[key].append(int(cells["duration"].text) / 1e6)
    return [
        {
            "category": category,
            "name": name,
            "count": len(values),
            "median_ms": round(statistics.median(values), 3),
            "p90_ms": round(percentile(values, 0.9), 3),
        }
        for (category, name), values in sorted(groups.items())
    ]


def main(argv):
    source, prefix = argv[1], argv[2]
    meta = {key: value for key, value in (item.split("=", 1) for item in argv[4:])} if argv[3:4] == ["--meta"] else {}
    intervals = summarize(source)
    # The output prefix is the operator's own command-line choice (profile_signposts.sh), not untrusted input.
    with open(prefix + ".json", "w") as handle:  # NOSONAR
        json.dump({"meta": meta, "intervals": intervals}, handle, indent=2)
        handle.write("\n")
    lines = [f"- {key}: {value}" for key, value in meta.items()]
    lines += ["", "| Category | Interval | Count | Median ms | p90 ms |", "|---|---|---:|---:|---:|"]
    lines += [f"| {i['category']} | {i['name']} | {i['count']} | {i['median_ms']} | {i['p90_ms']} |" for i in intervals]
    with open(prefix + ".md", "w") as handle:  # NOSONAR
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if not intervals:
        sys.exit("No com.marspater.news signpost intervals in " + source + "; check the schema in toc.xml")


if __name__ == "__main__":
    main(sys.argv)
