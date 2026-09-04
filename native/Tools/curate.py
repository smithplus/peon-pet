#!/usr/bin/env python3
"""Removes cross-category duplicates from installed peon-ping packs.

A sound reachable from two categories makes two different events sound the same,
which defeats the point of the tool. Fixing that is purely structural, so it can
be done for every pack without understanding the language: each file is kept in
its most specific category and dropped from the rest.

The original manifest is preserved as openpeon.json.orig, so --restore undoes it.
"""
import json
import os
import shutil
import sys

PACKS = os.path.expanduser("~/.openpeon/packs")

# Most specific first: the winner of a shared file. `input.required` outranks
# `task.complete` because the shared lines are almost always questions ("What?"),
# which belong to "I need you" rather than "done".
PRIORITY = [
    "task.error",
    "resource.limit",
    "input.required",
    "task.complete",
    "session.start",
    "task.acknowledge",
    "user.spam",
]


def rank(cat):
    return PRIORITY.index(cat) if cat in PRIORITY else len(PRIORITY)


def curate(manifest):
    """Returns (new_categories, moved, emptied_rescued)."""
    cats = manifest.get("categories", {})
    # file -> [categories referencing it]
    owners = {}
    for cat, block in cats.items():
        for s in block.get("sounds", []):
            owners.setdefault(s["file"], []).append(cat)

    winner = {f: min(cs, key=rank) for f, cs in owners.items()}

    new = {}
    moved = 0
    for cat, block in cats.items():
        kept = []
        for s in block.get("sounds", []):
            if winner[s["file"]] == cat:
                kept.append(s)
            else:
                moved += 1
        new[cat] = {"sounds": kept}

    # A category emptied by the dedup would go silent. Give it back the sound it
    # lost whose winning category can most afford to lose one.
    rescued = 0
    for cat, block in new.items():
        if block["sounds"]:
            continue
        candidates = [s for s in cats[cat].get("sounds", [])
                      if len(new[winner[s["file"]]]["sounds"]) > 1]
        if not candidates:
            candidates = cats[cat].get("sounds", [])
        if candidates:
            take = candidates[0]
            src = winner[take["file"]]
            # Never fall back to keeping it in both: that is the very defect
            # this tool exists to remove.
            new[src]["sounds"] = [x for x in new[src]["sounds"]
                                  if x["file"] != take["file"]]
            block["sounds"] = [take]
            winner[take["file"]] = cat
            rescued += 1
            moved -= 1
    return new, moved, rescued


def overlaps(cats):
    seen, dupes = set(), 0
    for block in cats.values():
        for s in block.get("sounds", []):
            if s["file"] in seen:
                dupes += 1
            seen.add(s["file"])
    return dupes


def process(name, restore=False, dry=False):
    d = os.path.join(PACKS, name)
    man = os.path.join(d, "openpeon.json")
    orig = man + ".orig"
    if not os.path.exists(man):
        return None

    if restore:
        if os.path.exists(orig):
            shutil.copy2(orig, man)
            os.remove(orig)
            return (name, "restaurado", 0, 0)
        return None

    manifest = json.load(open(man))
    before = overlaps(manifest.get("categories", {}))
    if before == 0:
        return (name, "ya estaba sano", 0, 0)

    new, moved, rescued = curate(manifest)

    # Packs with very few sounds cannot satisfy both rules at once. Leaving one
    # untouched is better than shipping a half-fixed manifest.
    if overlaps(new) != 0 or any(not b["sounds"] for b in new.values()):
        return (name, "omitido: muy pocos sonidos para separarlos", 0, 0)

    for cat, block in new.items():
        for s in block["sounds"]:
            if not os.path.exists(os.path.join(d, s["file"])):
                return (name, f"ERROR: falta {s['file']}", moved, rescued)

    if not dry:
        if not os.path.exists(orig):
            shutil.copy2(man, orig)
        manifest["categories"] = new
        with open(man, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, ensure_ascii=False, indent=2)
    return (name, f"-{moved} duplicados" + (f", +{rescued} rescatado" if rescued else ""),
            moved, rescued)


def main():
    restore = "--restore" in sys.argv
    dry = "--dry" in sys.argv
    names = sorted(n for n in os.listdir(PACKS)
                   if os.path.isdir(os.path.join(PACKS, n)))
    changed = errors = 0
    for n in names:
        r = process(n, restore=restore, dry=dry)
        if not r:
            continue
        name, msg, moved, _ = r
        if "ERROR" in msg:
            errors += 1
            print(f"  !! {name:24s} {msg}")
        elif "omitido" in msg:
            print(f"  -- {name:24s} {msg}")
        elif moved or restore:
            changed += 1
            print(f"  {name:24s} {msg}")
    print(f"\n{'restaurados' if restore else 'curados'}: {changed} · errores: {errors}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
