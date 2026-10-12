#!/usr/bin/env python3
"""Where did the context go? Sizes up Claude Code transcripts for this repo.

Reads ~/.claude/projects/*worklens*/*.jsonl (main checkout and every worktree) and prints, per
session, how many characters of tool results came back, from which tools, how much of it was
whole-file dumps (`cat`/`sed -n` in Bash), how many screenshots were Read and how large they
were, and how often the reference docs were re-read. Read-only, stdlib only.

Usage: python3 scripts/session-audit.py [--top N] [--sessions N] [glob]
"""
import collections
import glob
import json
import os
import sys

DOC_KEYS = ["PLAN.md", "architecture.md", "api-shapes.md", "decisions.md",
            ".env.example", "Package.swift", "gh issue view", "CLAUDE.md"]
DUMP_MARKERS = ("cat ", "cat -n", "sed -n")


def size(content):
    return len(content) if isinstance(content, str) else len(json.dumps(content))


def audit(path):
    tools = {}
    by_tool = collections.Counter()
    calls = collections.Counter()
    docs = collections.Counter()
    biggest = []
    dumps = images = image_bytes = msgs = 0
    with open(path) as fh:
        for line in fh:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if m.get("type") in ("user", "assistant"):
                msgs += 1
            content = (m.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for block in content:
                kind = block.get("type")
                if kind == "tool_use":
                    tools[block["id"]] = (block["name"], block.get("input") or {})
                elif kind == "tool_result":
                    name, inp = tools.get(block.get("tool_use_id"), ("?", {}))
                    raw = block.get("content")
                    n = size(raw)
                    by_tool[name] += n
                    calls[name] += 1
                    inp_s = json.dumps(inp)
                    for key in DOC_KEYS:
                        if key in inp_s:
                            docs[key] += 1
                    if name == "Read" and not isinstance(raw, str) and '"image"' in json.dumps(raw)[:40]:
                        images += 1
                        image_bytes += n
                        continue
                    if name == "Bash" and any(k in inp.get("command", "") for k in DUMP_MARKERS):
                        dumps += n
                    label = inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                    biggest.append((n, name, str(label)[:80].replace("\n", " ")))
    return dict(msgs=msgs, by_tool=by_tool, calls=calls, docs=docs, biggest=sorted(biggest, reverse=True),
                dumps=dumps, images=images, image_bytes=image_bytes, total=sum(by_tool.values()))


def main(argv):
    top, sessions, pattern = 10, 6, "~/.claude/projects/*worklens*/*.jsonl"
    it = iter(argv)
    for a in it:
        if a == "--top":
            top = int(next(it))
        elif a == "--sessions":
            sessions = int(next(it))
        else:
            pattern = a
    files = sorted(glob.glob(os.path.expanduser(pattern)), key=os.path.getsize)
    if not files:
        print("no transcripts match", pattern)
        return 1
    print(f"{len(files)} sessions, {sum(os.path.getsize(f) for f in files) // 1024 // 1024} MB of transcripts; "
          f"showing the {min(sessions, len(files))} largest\n")
    for f in files[-sessions:]:
        r = audit(f)
        proj = os.path.basename(os.path.dirname(f)).split("worktrees-")[-1][:28]
        print(f"== {os.path.basename(f)[:8]}  {proj}  {os.path.getsize(f) // 1024} KB  {r['msgs']} msgs  "
              f"tool results {r['total'] // 1000}k chars ({r['total'] // r['msgs'] if r['msgs'] else 0}/msg)")
        print(f"   whole-file dumps via Bash: {r['dumps'] // 1000}k chars   "
              f"screenshots Read: {r['images']} ({r['image_bytes'] // 1024} KB base64)")
        print("   by tool: " + ", ".join(f"{k} {v // 1000}k×{r['calls'][k]}" for k, v in r["by_tool"].most_common(6)))
        if r["docs"]:
            print("   doc reads: " + ", ".join(f"{k}×{v}" for k, v in r["docs"].most_common()))
        for n, name, label in r["biggest"][:top]:
            print(f"   {n // 1000:5d}k {name:12s} {label}")
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
