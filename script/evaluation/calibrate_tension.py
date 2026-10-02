#!/usr/bin/env python3
"""
Calibrate and validate the News Tension Index on the historical sample corpus (Issue #158).
Verifies classification accuracy on historical sample facts, evaluates edge cases
(negations, reversals, historical years), computes daily event scores, saturating
index scaling (0-100), and trailing EMA smoothing across gaps.
"""
import json
import math
import os
import re
import sys
from pathlib import Path

FIXTURE_PATH = Path(__file__).resolve().parents[2] / "Tests/Fixtures/tension-corpus/historical-sample.json"

# Cues matching TensionMethodology.swift
TYPE_CUES = {
    "armedConflict": [
        "airstrike", "airstrikes", "air strike", "air strikes", "missile strike", "missile strikes", "drone strike",
        "drone strikes", "drone attack", "drone attacks", "shelling", "shelled", "artillery", "bombardment",
        "offensive", "invasion", "invaded", "troops", "front line", "frontline", "fighting", "military operation",
        "ceasefire", "cease fire", "insurgents"
    ],
    "terrorism": [
        "terrorist", "terrorists", "terrorism", "terror attack", "suicide bomber", "suicide bombing", "car bomb",
        "gunman", "gunmen", "mass shooting", "hostage", "hostages", "kidnapped", "abducted", "explosive device"
    ],
    "civilUnrest": [
        "protest", "protests", "protesters", "protestors", "demonstrators", "riot", "riots", "rioting", "unrest",
        "curfew", "tear gas", "crackdown", "coup", "uprising", "martial law"
    ],
    "coercion": [
        "sanctions", "embargo", "blockade", "ultimatum", "mobilization", "mobilisation", "military drills",
        "nuclear test", "missile test", "ballistic missile", "expelled diplomats", "troop buildup"
    ],
    "disaster": [
        "earthquake", "tsunami", "hurricane", "typhoon", "cyclone", "flood", "floods", "flooding", "wildfire",
        "wildfires", "landslide", "eruption", "drought", "heatwave", "heat wave", "famine", "derailment"
    ],
    "healthEmergency": [
        "outbreak", "epidemic", "pandemic", "cholera", "ebola", "mpox", "public health emergency"
    ],
    "cyberAttack": [
        "cyberattack", "cyberattacks", "cyber attack", "cyber attacks", "ransomware", "data breach", "ddos"
    ]
}

ESCALATING_CUES = [
    "escalate", "escalated", "escalates", "escalating", "escalation", "intensified", "intensifies", "intensifying",
    "stepped up", "new offensive", "launched an offensive", "renewed fighting", "renewed attacks", "declared war",
    "retaliated", "retaliatory", "mobilized", "mobilised", "deployed additional", "state of emergency"
]

DEESCALATING_CUES = [
    "ceasefire", "cease fire", "truce", "armistice", "peace talks", "peace deal", "peace agreement", "de escalation",
    "de escalate", "deescalation", "withdrew", "withdrawal", "pulled back", "prisoner exchange", "prisoner swap",
    "released hostages", "hostages were released", "lifted the curfew", "lifted sanctions", "resumed talks"
]

NEGATIONS = {"no", "not", "never", "without", "rejected", "rejects", "refused", "refuses", "denied", "denies", "ruled"}
REVERSALS = {"collapsed", "collapses", "failed", "fails", "broke", "violated", "ended", "stalled", "faltered"}

# Panel definitions
PANEL_REGIONS = {
    "bbc-world": "europe",
    "guardian-world": "europe",
    "dw-english": "europe",
    "france-24": "europe",
    "euronews": "europe",
    "cbc-world": "northAmerica",
    "al-jazeera": "middleEastNorthAfrica",
    "arab-news": "middleEastNorthAfrica",
    "the-hindu": "southAsia",
    "dawn": "southAsia",
    "cna": "eastSoutheastAsia",
    "africanews": "subSaharanAfrica"
}

TYPE_WEIGHTS = {
    "armedConflict": 10.0,
    "terrorism": 8.0,
    "disaster": 6.0,
    "civilUnrest": 4.0,
    "coercion": 4.0,
    "healthEmergency": 4.0,
    "cyberAttack": 3.0
}

DEATH_MULTIPLIERS = {
    "notReported": 1.0,
    "units": 1.2,
    "tens": 1.5,
    "hundreds": 2.0,
    "thousands": 2.5
}

AFFECTED_MULTIPLIERS = {
    "notReported": 1.0,
    "units": 1.1,
    "tens": 1.25,
    "hundreds": 1.5,
    "thousands": 2.0
}

ESCALATION_MULTIPLIERS = {
    "noSignal": 1.0,
    "escalating": 1.3,
    "deescalating": 0.7,
    "mixed": 1.0
}

BREADTH_MULTIPLIERS = {
    1: 0.85,
    2: 1.0,
    3: 1.15,
    4: 1.30
}

SCALE_FACTOR = 25.0
SMOOTHING_ALPHA = 0.25  # 7-day trailing EMA: alpha = 2 / (7 + 1) = 0.25


def tokenize_words(text: str):
    return [w for w in re.split(r'[^a-zA-Z0-9]+', text.lower()) if w]


def contains_cue(words, cues, reversible=False):
    for cue in cues:
        cue_words = tokenize_words(cue)
        if not cue_words or len(cue_words) > len(words):
            continue
        c_len = len(cue_words)
        for i in range(len(words) - c_len + 1):
            if words[i:i + c_len] == cue_words:
                prev_words = words[max(0, i - 3):i]
                if any(w in NEGATIONS for w in prev_words):
                    continue
                if reversible:
                    next_words = words[i + c_len:min(len(words), i + c_len + 3)]
                    if any(w in REVERSALS for w in next_words):
                        continue
                return True
    return False


DEATH_WORDS = {"killed", "dead", "died", "deaths", "fatalities", "killing", "kills"}
HARM_WORDS = {"killed", "dead", "died", "deaths", "fatalities", "injured", "wounded", "hurt", "displaced", "evacuated", "missing", "hospitalised", "hospitalized", "homeless"}
QUANTITIES = {"dozens": 24, "scores": 40, "hundreds": 200, "thousands": 2000, "millions": 2000000}


def extract_figures(quote: str):
    text = quote.lower()
    deaths = 0
    affected = 0

    def parse_fig(n_str, m_str):
        if not m_str and "," not in n_str and "." not in n_str:
            try:
                yr = int(n_str)
                if 1900 <= yr <= 2099:
                    return None
            except ValueError:
                pass
        try:
            val = float(n_str.replace(",", ""))
            mult = 1000000 if m_str == "million" else 1000 if m_str == "thousand" else 1
            res = val * mult
            if 1 <= res < 1e12:
                return int(res)
        except ValueError:
            pass
        return None

    # Pattern 1 & 2: number [person] [aux] harm
    num_re = r'(\d{1,3}(?:,\d{3})+|\d+(?:\.\d+)?)(?:\s+(thousand|million))?'
    aux_re = r'(?:(?:were|was|have|has|had|are|is|been|being|now|reportedly)\s+){0,3}'
    person_re = r'(?:people|persons|civilians|soldiers|troops|children|residents|others|migrants|workers|passengers|fighters|militants|police|officers|protesters|demonstrators|villagers|patients|refugees|students|journalists|members|adults|women|men)'
    harm_re = r'(killed|dead|died|deaths|fatalities|injured|wounded|hurt|displaced|evacuated|missing|hospitali[sz]ed|homeless)'
    qual_re = r'(?:(?:at least|more than|over|about|around|nearly|almost|some|up to)\s+)?'

    p1 = re.compile(rf'\b{num_re}\s+(?:(?:more|other)\s+)?(?:[a-z]+\s+)?{person_re}\s+{aux_re}{harm_re}\b')
    p2 = re.compile(rf'\b{num_re}\s+{aux_re}{harm_re}\b')
    p3 = re.compile(rf'\b(killing|killed|kills|injuring|injured|wounding|wounded|displacing|displaced)\s+{qual_re}{num_re}\b')
    p4 = re.compile(rf'\b(?:death toll|toll)\b[^.;]{{0,40}}?\b(?:to|at|of|reached|hit|passed|surpassed|exceeded)\s+{qual_re}{num_re}\b')
    p5 = re.compile(rf'\b(dozens|scores|hundreds|thousands|millions)\s+(?:of\s+)?(?:[a-z]+\s+){{0,2}}?{aux_re}{harm_re}\b')

    for m in p1.finditer(text):
        count = parse_fig(m.group(1), m.group(2))
        h = m.group(3)
        if count:
            if h in DEATH_WORDS:
                deaths = max(deaths, count)
            else:
                affected = max(affected, count)

    for m in p2.finditer(text):
        count = parse_fig(m.group(1), m.group(2))
        h = m.group(3)
        if count:
            if h in DEATH_WORDS:
                deaths = max(deaths, count)
            else:
                affected = max(affected, count)

    for m in p3.finditer(text):
        h = m.group(1)
        count = parse_fig(m.group(2), m.group(3))
        if count:
            if h in DEATH_WORDS:
                deaths = max(deaths, count)
            else:
                affected = max(affected, count)

    for m in p4.finditer(text):
        count = parse_fig(m.group(1), m.group(2))
        if count:
            deaths = max(deaths, count)

    for m in p5.finditer(text):
        q = m.group(1)
        h = m.group(2)
        count = QUANTITIES.get(q)
        if count:
            if h in DEATH_WORDS:
                deaths = max(deaths, count)
            else:
                affected = max(affected, count)

    def mag(c):
        if c < 1:
            return "notReported"
        if c < 10:
            return "units"
        if c < 100:
            return "tens"
        if c < 1000:
            return "hundreds"
        return "thousands"

    return mag(deaths), mag(affected)


def classify_event(facts):
    type_counts = {t: 0 for t in TYPE_CUES}
    escalating_count = 0
    deescalating_count = 0
    best_deaths = "notReported"
    best_affected = "notReported"

    mag_rank = {"notReported": 0, "units": 1, "tens": 2, "hundreds": 3, "thousands": 4}

    for f in facts:
        words = tokenize_words(f["quote"])
        for t, cues in TYPE_CUES.items():
            if contains_cue(words, cues):
                type_counts[t] += 1
        if contains_cue(words, ESCALATING_CUES):
            escalating_count += 1
        if contains_cue(words, DEESCALATING_CUES, reversible=True):
            deescalating_count += 1
        d_mag, a_mag = extract_figures(f["quote"])
        if mag_rank[d_mag] > mag_rank[best_deaths]:
            best_deaths = d_mag
        if mag_rank[a_mag] > mag_rank[best_affected]:
            best_affected = a_mag

    detected_type = None
    best_type_count = 0
    for t in TYPE_CUES:
        if type_counts[t] > best_type_count:
            best_type_count = type_counts[t]
            detected_type = t

    if escalating_count > 0 and deescalating_count > 0:
        escalation = "mixed"
    elif escalating_count > 0:
        escalation = "escalating"
    elif deescalating_count > 0:
        escalation = "deescalating"
    else:
        escalation = "noSignal"

    return detected_type, best_deaths, best_affected, escalation


def score_event(event_type, deaths, affected, escalation, reporting_catalog_ids):
    if not event_type:
        return 0.0, 0.0, 1.0, 1.0, 1.0
    t_weight = TYPE_WEIGHTS.get(event_type, 0.0)
    d_mult = DEATH_MULTIPLIERS.get(deaths, 1.0)
    a_mult = AFFECTED_MULTIPLIERS.get(affected, 1.0)
    m_mult = max(d_mult, a_mult)
    e_mult = ESCALATION_MULTIPLIERS.get(escalation, 1.0)

    regions = set(PANEL_REGIONS[cid] for cid in reporting_catalog_ids if cid in PANEL_REGIONS)
    reg_count = len(regions)
    if reg_count <= 1:
        b_mult = BREADTH_MULTIPLIERS[1]
    elif reg_count == 2:
        b_mult = BREADTH_MULTIPLIERS[2]
    elif reg_count == 3:
        b_mult = BREADTH_MULTIPLIERS[3]
    else:
        b_mult = BREADTH_MULTIPLIERS[4]

    raw = t_weight * m_mult * e_mult * b_mult
    return raw, t_weight, m_mult, e_mult, b_mult


def scale_raw(raw):
    if raw <= 0:
        return 0.0
    return 100.0 * (1.0 - math.exp(-raw / SCALE_FACTOR))


def run_calibration():
    with open(FIXTURE_PATH, "r", encoding="utf-8") as f:
        corpus = json.load(f)

    sample_days = corpus.get("sampleDays", [])
    print(f"Loaded {len(sample_days)} sample days from {FIXTURE_PATH.name}")

    total_events = 0
    correct_types = 0
    correct_deaths = 0
    correct_affected = 0
    correct_escalations = 0

    day_results = []
    last_smoothed = None

    for day in sample_days:
        day_id = day["id"]
        status = day["expectedCoverageStatus"]
        events = day.get("events", [])
        raw_day_score = 0.0

        for evt in events:
            total_events += 1
            evt_id = evt["id"]
            facts = evt["facts"]
            exp_type = evt["expectedType"]
            exp_deaths = evt["expectedDeaths"]
            exp_affected = evt["expectedAffected"]
            exp_esc = evt["expectedEscalation"]

            c_type, c_deaths, c_affected, c_esc = classify_event(facts)

            if c_type == exp_type:
                correct_types += 1
            else:
                print(f"Type mismatch on {evt_id}: got {c_type}, expected {exp_type}")

            if c_deaths == exp_deaths:
                correct_deaths += 1
            else:
                print(f"Deaths mismatch on {evt_id}: got {c_deaths}, expected {exp_deaths}")

            if c_affected == exp_affected:
                correct_affected += 1
            else:
                print(f"Affected mismatch on {evt_id}: got {c_affected}, expected {exp_affected}")

            if c_esc == exp_esc:
                correct_escalations += 1
            else:
                print(f"Escalation mismatch on {evt_id}: got {c_esc}, expected {exp_esc}")

            raw_evt, tw, mm, em, bm = score_event(c_type, c_deaths, c_affected, c_esc, evt["reportingCatalogIDs"])
            raw_day_score += raw_evt

        if status == "sufficient":
            calibrated_idx = scale_raw(raw_day_score)
            if last_smoothed is None:
                smoothed_idx = calibrated_idx
            else:
                smoothed_idx = SMOOTHING_ALPHA * calibrated_idx + (1.0 - SMOOTHING_ALPHA) * last_smoothed
            last_smoothed = smoothed_idx
        else:
            # GAPS ARE NEVER ZERO
            calibrated_idx = None
            smoothed_idx = None

        day_results.append({
            "id": day_id,
            "status": status,
            "raw": raw_day_score if status == "sufficient" else None,
            "calibrated": calibrated_idx,
            "smoothed": smoothed_idx
        })

    print("\n--- Classification Performance on Historical Sample ---")
    print(f"Total Events: {total_events}")
    print(f"Type Accuracy:       {correct_types}/{total_events} ({correct_types/total_events*100:.1f}%)")
    print(f"Deaths Accuracy:     {correct_deaths}/{total_events} ({correct_deaths/total_events*100:.1f}%)")
    print(f"Affected Accuracy:   {correct_affected}/{total_events} ({correct_affected/total_events*100:.1f}%)")
    print(f"Escalation Accuracy: {correct_escalations}/{total_events} ({correct_escalations/total_events*100:.1f}%)")

    assert correct_types == total_events, "Type accuracy must be 100% on sample"
    assert correct_deaths == total_events, "Deaths magnitude accuracy must be 100% on sample"
    assert correct_affected == total_events, "Affected magnitude accuracy must be 100% on sample"
    assert correct_escalations == total_events, "Escalation accuracy must be 100% on sample"

    print("\n--- Calibrated Tension Index Series Across Observation Days ---")
    print(f"{'Day ID':<38} | {'Status':<12} | {'Raw':>7} | {'Index':>7} | {'Smoothed':>8}")
    print("-" * 82)
    for r in day_results:
        raw_str = f"{r['raw']:.2f}" if r["raw"] is not None else "N/A"
        idx_str = f"{r['calibrated']:.1f}" if r["calibrated"] is not None else "N/A"
        sm_str = f"{r['smoothed']:.1f}" if r["smoothed"] is not None else "N/A"
        print(f"{r['id']:<38} | {r['status']:<12} | {raw_str:>7} | {idx_str:>7} | {sm_str:>8}")

    # Verify edge cases:
    # Day 9 (negations) must be 0.0
    d9 = next(d for d in day_results if "negations" in d["id"])
    assert d9["raw"] == 0.0 and d9["calibrated"] == 0.0, "Day 9 negations must have raw=0 and calibrated=0"

    # Day 11 (historical years) must be 0.0
    d11 = next(d for d in day_results if "historical-years" in d["id"])
    assert d11["raw"] == 0.0 and d11["calibrated"] == 0.0, "Day 11 historical years must have raw=0 and calibrated=0"

    # Days 12, 13, 14 must have None index (never 0.0)
    for gap_id in ["insufficient-feeds", "insufficient-regions", "no-data"]:
        gap_day = next(d for d in day_results if gap_id in d["id"])
        assert gap_day["calibrated"] is None, f"{gap_id} must have calibrated=None"
        assert gap_day["smoothed"] is None, f"{gap_id} must have smoothed=None"

    print("\nAll historical calibration assertions passed successfully!")


if __name__ == "__main__":
    run_calibration()
