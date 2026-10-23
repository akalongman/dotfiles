#!/usr/bin/env bash
# Fetch a GitLab MR's metadata, changed files and every discussion (paginated),
# and write a previous-reviews digest for the subagent brief.
#
# usage: bash fetch-gitlab-mr.sh <url-encoded namespace/repo> <out dir> <iid>...
# writes: <out dir>/<iid>.meta.json, <iid>.diffs.json, <iid>.discussions.json, <iid>.reviews.txt
# prints: one summary block per MR (state, branches, SHAs, files, discussion counts)
set -euo pipefail
repo="$1"; out="$2"; shift 2
mkdir -p "$out"
for iid in "$@"; do
    glab api "projects/$repo/merge_requests/$iid" > "$out/$iid.meta.json"
    glab api "projects/$repo/merge_requests/$iid/diffs" --paginate > "$out/$iid.diffs.json"
    glab api "projects/$repo/merge_requests/$iid/discussions" --paginate > "$out/$iid.discussions.json"
    python3 -I - "$out" "$iid" <<'PY'
import json, sys
out, iid = sys.argv[1], sys.argv[2]

def load_pages(path):
    # --paginate concatenates one JSON document per page; decode them all.
    raw = open(path).read(); dec = json.JSONDecoder(); pos = 0; items = []
    while True:
        while pos < len(raw) and raw[pos].isspace(): pos += 1
        if pos >= len(raw): return items
        obj, pos = dec.raw_decode(raw, pos)
        items.extend(obj if isinstance(obj, list) else [obj])

m = json.load(open(f"{out}/{iid}.meta.json"))
r = m["diff_refs"]
print(f"!{iid} {m['state']} {m['source_branch']} -> {m['target_branch']} head={m['sha']}")
print(f"  base={r['base_sha']} start={r['start_sha']} head={r['head_sha']}")
print(f"  title: {m['title']}")
print(f"  labels: {', '.join(m['labels']) or 'none'}")
paths = [d["new_path"] for d in load_pages(f"{out}/{iid}.diffs.json")]
print(f"  files ({len(paths)}):")
for p in paths:
    print(f"    {p}")
discs = [d for d in load_pages(f"{out}/{iid}.discussions.json") if not d["notes"][0]["system"]]
threads = [d for d in discs if d["notes"][0]["resolvable"]]
mr_notes = [d for d in discs if not d["notes"][0]["resolvable"]]
open_t = [d for d in threads if not d["notes"][0]["resolved"]]
print(f"  discussions: {len(mr_notes)} MR-level notes, {len(threads)} threads ({len(open_t)} open)")
with open(f"{out}/{iid}.reviews.txt", "w") as f:
    for d in mr_notes:
        n = d["notes"][0]
        f.write(f"NOTE | {n['author']['username']} | {n['created_at'][:10]}\n  " + n["body"].replace("\n", "\n  ") + "\n\n")
    for d in threads:
        n = d["notes"][0]; p = n.get("position") or {}
        anchor = f"{p.get('new_path')}:{p.get('new_line')}" if p else "no anchor"
        f.write(f"THREAD {d['id']} | {n['author']['username']} | {anchor} | resolved={n['resolved']}\n  " + n["body"].replace("\n", "\n  ") + "\n")
        for rep in d["notes"][1:]:
            f.write(f"  -- reply by {rep['author']['username']}: " + rep["body"].replace("\n", "\n     ") + "\n")
        f.write("\n")
PY
done
