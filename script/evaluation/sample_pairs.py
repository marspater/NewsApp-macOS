#!/usr/bin/env python3
"""Prints a fixed pseudo-random sample of one decision class from a --review-pairs export (#551): rows sorted by the
SHA-256 of the two article ids, so a rerun draws the same rows. Usage: sample_pairs.py pairs-review.csv match 0 200."""
import csv, hashlib, sys, json
path = sys.argv[1]; which = sys.argv[2]; start=int(sys.argv[3]); end=int(sys.argv[4])
rows = list(csv.DictReader(open(path, newline='')))
def key(r): return hashlib.sha256((r['article_id']+r['other_article_id']).encode()).hexdigest()
if which == 'match': sel = [r for r in rows if r['decision']=='match' and r['reason']=='match']
elif which == 'pairModel': sel = [r for r in rows if r['decision']=='match' and r['reason']=='pairModel']
elif which == 'related': sel = [r for r in rows if r['decision']=='related-act']
elif which == 'vetoed': sel = [r for r in rows if r['decision']=='vetoed']
else: sel = [r for r in rows if r['decision']=='borderline']
sel.sort(key=key)
print(f"{which}: {len(sel)} rows")
for i, r in enumerate(sel[start:end], start=start+1):
    gap = (float(r['published_b'])-float(r['published_a']))/3600
    print(f"{i:3d} [{gap:+.1f}h s={float(r['score']):.2f}] {r['source_a']}: {r['title_a']} || {r['source_b']}: {r['title_b']}")
