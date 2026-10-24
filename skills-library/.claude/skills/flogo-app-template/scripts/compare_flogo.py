"""Compare two .flogo files structurally, ignoring the UUIDs fda generates (connection / spec ids).

    python scripts/compare_flogo.py <golden>/<App>.flogo generated/<App>/<App>.flogo
Exit code 0 = identical apart from generated ids.
"""
import json
import re
import sys

UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def normalize(path):
    """Renumber only the ids fda generates: the keys of the top-level `connections` / `specs` maps, which the
    rest of the app references as conn://<id> / spec://<id>. Other UUID-shaped values (property or mapping
    literals) are configuration and are compared as-is."""
    text = open(path, encoding="utf-8").read()
    app = json.loads(text)
    # Each generated id becomes a stable name: <connection:EventBus>, <spec:FlightOpsApi>. Entries sharing a name are
    # numbered by their content (id removed), so neither the file's key order nor the ids themselves matter.
    stable = {}
    for section in ("connections", "specs"):
        groups = {}
        for k, v in (app.get(section) or {}).items():
            if UUID.fullmatch(k):
                groups.setdefault(str((v or {}).get("name") or "?"), []).append(k)
        for name, ids in groups.items():
            body = lambda k: json.dumps({x: y for x, y in app[section][k].items() if x != "id"}, sort_keys=True)
            for n, k in enumerate(sorted(ids, key=body), start=1):
                stable[k] = f"<{section[:-1]}:{name}>" if len(ids) == 1 else f"<{section[:-1]}:{name}#{n}>"
    text = UUID.sub(lambda m: stable.get(m.group(0), m.group(0)), text)
    return json.loads(text)


def diff(a, b, path="$", out=None):
    out = [] if out is None else out
    if type(a) is not type(b):
        out.append(f"{path}: {type(a).__name__} != {type(b).__name__}")
    elif isinstance(a, dict):
        for k in sorted(set(a) | set(b)):
            if k not in a or k not in b:
                out.append(f"{path}.{k}: only in {'second' if k not in a else 'first'}")
            else:
                diff(a[k], b[k], f"{path}.{k}", out)
    elif isinstance(a, list):
        if len(a) != len(b):
            out.append(f"{path}: {len(a)} items != {len(b)} items")
        for i, (x, y) in enumerate(zip(a, b)):
            diff(x, y, f"{path}[{i}]", out)
    elif a != b:
        out.append(f"{path}: {str(a)[:60]!r} != {str(b)[:60]!r}")
    return out


if __name__ == "__main__":
    d = diff(normalize(sys.argv[1]), normalize(sys.argv[2]))
    if d:
        print(f"DIFFERENT ({len(d)} differences)")
        for line in d[:40]:
            print("  " + line)
        sys.exit(1)
    print("IDENTICAL (apart from generated ids)")
