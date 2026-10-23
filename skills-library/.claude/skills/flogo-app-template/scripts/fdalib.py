"""Shared helpers for the Flogo app-template demo (harvest.py / generate_app.py).

Everything here is deterministic: the same inputs always produce the same
parameters, mapping rows and fda command lines.
"""
import glob
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def _find_config():
    """Walk up from this script and from the cwd to the skills-library `.claude/skills/config.md`."""
    for start in (HERE, os.getcwd()):
        d = start
        while True:
            for cand in (os.path.join(d, "config.md"), os.path.join(d, ".claude", "skills", "config.md")):
                if os.path.basename(os.path.dirname(cand)) == "skills" and os.path.exists(cand):
                    return cand
            parent = os.path.dirname(d)
            if parent == d:
                break
            d = parent
    return ""


CONFIG_MD = _find_config()

ANSI = re.compile(r"\x1b\[[0-9;]*m")

# Activity / connection names fixed by the template pattern (see pattern-guide.md).
MAPPER = "BuildEvent"
PROPERTIES = {"Event.Topic", "Kafka.EventBus.Brokers", "HTTP.Port"}


class TemplateError(Exception):
    pass


# --------------------------------------------------------------------------- config / CLI

def read_config():
    """Return {KEY: value} from the `| KEY | `value` |` rows of config.md (empty if missing)."""
    cfg = {}
    if CONFIG_MD:
        for line in open(CONFIG_MD, encoding="utf-8"):
            m = re.match(r"\|\s*([A-Z_]+)\s*\|\s*`([^`]*)`", line)
            if m:
                cfg[m.group(1)] = m.group(2)
    return cfg


def resolve_fda():
    """FDA env var -> newest tibco.flogo-* VS Code extension -> config.md FLOGODESIGN_CLI_PATH."""
    if os.environ.get("FDA"):
        return os.environ["FDA"]
    exe = "flogodesign-cli.exe" if os.name == "nt" else "flogodesign-cli"
    home = os.path.expanduser("~")
    for root in (".vscode", ".vscode-insiders", ".vscode-server"):
        hits = glob.glob(os.path.join(home, root, "extensions", "tibco.flogo-*", "bin", exe))
        if hits:
            return max(hits, key=os.path.getmtime)
    p = read_config().get("FLOGODESIGN_CLI_PATH")
    if p and os.path.exists(os.path.join(p, exe)):
        return os.path.join(p, exe)
    raise TemplateError("flogodesign-cli (fda) not found - install the TIBCO Flogo VS Code extension")


def fda_env():
    env = dict(os.environ)
    env["MSYS_NO_PATHCONV"] = "1"
    env["FLOGO_DESIGN_ENABLE_HISTORY"] = "true"
    return env


def fda_version(fda):
    out = subprocess.run([fda, "version"], capture_output=True, text=True, encoding="utf-8", errors="replace")
    return ANSI.sub("", out.stdout + out.stderr).strip()


def run_fda(fda, argv, flogo, cwd):
    """Run one fda command; return (ok, last_message)."""
    p = subprocess.run([fda, *argv, "-f", flogo], cwd=cwd, env=fda_env(), capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    out = ANSI.sub("", p.stdout + p.stderr)
    lines = [l for l in out.splitlines()
             if l.strip() and "DEP0169" not in l and "trace-deprecation" not in l and "History Enabled" not in l]
    ok = p.returncode == 0 and "(ERROR)" not in out
    return ok, (lines[-1] if lines else "").replace("[Flogo Design] ", "").strip()


# --------------------------------------------------------------------------- OpenAPI

def _resolve(node, spec):
    if isinstance(node, dict):
        if "$ref" in node:
            name = node["$ref"].split("/")[-1]
            return _resolve(spec["components"]["schemas"][name], spec)
        return {k: _resolve(v, spec) for k, v in node.items() if k != "example"}
    if isinstance(node, list):
        return [_resolve(v, spec) for v in node]
    return node


def read_spec(path, operation_id):
    """Return the facts the template needs from an OpenAPI 3 (JSON) spec."""
    spec = json.load(open(path, encoding="utf-8"))
    for api_path, ops in spec.get("paths", {}).items():
        for method, op in ops.items():
            if isinstance(op, dict) and op.get("operationId") == operation_id:
                body = op.get("requestBody", {}).get("content", {}).get("application/json", {}).get("schema")
                if body is None:
                    raise TemplateError(f"operation {operation_id} has no application/json request body")
                code, reply = None, None
                for c, r in sorted(op.get("responses", {}).items()):
                    s = r.get("content", {}).get("application/json", {}).get("schema")
                    if c.startswith("2") and s:
                        code, reply = c, s
                        break
                if reply is None:
                    raise TemplateError(f"operation {operation_id} has no 2xx application/json response")
                return {
                    "title": spec["info"]["title"],
                    "path": api_path,
                    "method": method.upper(),
                    "request": _resolve(body, spec),
                    "replyCode": code,
                    "reply": _resolve(reply, spec),
                }
    raise TemplateError(f"operationId '{operation_id}' not found in {path}")


def trigger_name(title):
    """Name `fda cas` gives the tr_rest trigger: the spec title with non-alphanumerics as `_`."""
    return re.sub(r"[^A-Za-z0-9]", "_", title)


# --------------------------------------------------------------------------- mapping workbook

FUNCS = {
    "UPPER": "string.toUpper", "LOWER": "string.toLower", "TRIM": "string.trim",
    "concat": "string.concat", "CONCAT": "string.concat", "LENGTH": "string.length",
    "SUBSTRING": "string.substring", "REPLACE": "string.replaceAll",
    "newUUID": "utils.uuid", "now": "datetime.now",
    "asString": "coerce.toString", "asInt": "coerce.toInt", "asNumber": "coerce.toFloat64",
}
QUALIFIED_PKGS = {"string", "datetime", "coerce", "utils", "number", "array", "json", "math", "boolean"}
JSON_TYPES = {"string", "integer", "number", "boolean"}


def read_workbook(path):
    from openpyxl import load_workbook  # only needed when a workbook is read

    wb = load_workbook(path, data_only=True)
    sheets = {}
    for name in ("Event", "Response"):
        if name not in wb.sheetnames:
            raise TemplateError(f"{os.path.basename(path)}: missing sheet '{name}'")
        rows = []
        for i, r in enumerate(wb[name].iter_rows(min_row=2, values_only=True), start=2):
            target, typ, rule = (r + (None, None, None))[:3]
            if not target:
                continue
            rows.append({"row": i, "target": str(target).strip(), "type": str(typ or "string").strip().lower(),
                         "rule": "" if rule is None else str(rule).strip()})
        sheets[name] = rows
    return sheets


def _top_fields(schema):
    return set((schema or {}).get("properties", {}).keys())


def translate(rule, typ, where, request_fields, event_fields):
    """Translate one friendly mapping rule into (value, extra_fda_args)."""
    if rule.startswith("="):
        return rule, []
    m = re.fullmatch(r'"([^"]*)"', rule)
    if m:
        return m.group(1), []
    if typ in ("integer", "number") and re.fullmatch(r"-?\d+(\.\d+)?", rule):
        return rule, ["--type", "number"]
    if typ == "boolean" and rule.lower() in ("true", "false"):
        return rule.lower(), ["--type", "boolean"]

    out, i = [], 0
    while i < len(rule):
        ch = rule[i]
        if ch == '"':
            j = i + 1
            while j < len(rule) and (rule[j] != '"' or rule[j - 1] == "\\"):
                j += 1
            out.append(rule[i:j + 1])
            i = j + 1
        elif ch == "[":
            j = rule.index("]", i)
            prop = rule[i + 1:j]
            if prop not in PROPERTIES:
                raise TemplateError(f"{where}: unknown app property [{prop}] (known: {', '.join(sorted(PROPERTIES))})")
            out.append(f'$property["{prop}"]')
            i = j + 1
        elif ch.isalpha() or ch == "_":
            m = re.match(r"[A-Za-z_][\w.]*", rule[i:])
            ident = m.group(0)
            i += len(ident)
            rest = rule[i:].lstrip()
            if rest.startswith("("):
                if ident in FUNCS:
                    out.append(FUNCS[ident])
                elif ident.split(".")[0] in QUALIFIED_PKGS and "." in ident:
                    out.append(ident)
                else:
                    raise TemplateError(f"{where}: unknown function {ident}() (known: {', '.join(sorted(FUNCS))})")
            elif ident.startswith("request."):
                field = ident.split(".")[1]
                if field not in request_fields:
                    raise TemplateError(f"{where}: request.{field} is not in the API request body "
                                        f"(fields: {', '.join(sorted(request_fields))})")
                out.append("$flow.body." + ident[len("request."):])
            elif ident.startswith("event."):
                if event_fields is None:
                    raise TemplateError(f"{where}: event.* can only be used on the Response sheet")
                if ident[len("event."):] not in event_fields:
                    raise TemplateError(f"{where}: {ident} is not a target on the Event sheet")
                out.append(f"$activity[{MAPPER}].output." + ident[len("event."):])
            elif ident in ("true", "false", "nil"):
                out.append(ident)
            else:
                raise TemplateError(f"{where}: don't know what '{ident}' refers to "
                                    f"(use request.<field>, event.<field>, [Property] or \"literal\")")
        else:
            out.append(ch)
            i += 1
    return "=" + "".join(out), []


def event_schema(rows):
    """Nested JSON schema built from the dotted Event-sheet targets, in sheet order."""
    root = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "properties": {}}
    for r in rows:
        if r["type"] not in JSON_TYPES:
            raise TemplateError(f"Event row {r['row']}: type '{r['type']}' must be one of {sorted(JSON_TYPES)}")
        node = root
        parts = r["target"].split(".")
        for p in parts[:-1]:
            node = node["properties"].setdefault(p, {"type": "object", "properties": {}})
        node["properties"][parts[-1]] = {"type": r["type"]}
    return root


# --------------------------------------------------------------------------- parameters

def derive(params_path):
    """All template parameters and @foreach rows, derived from one <app>.params.json."""
    base = os.path.dirname(os.path.abspath(params_path))
    p = json.load(open(params_path, encoding="utf-8"))
    for k in ("appName", "description", "swagger", "operationId", "mappingWorkbook",
              "eventSchemaName", "keyField", "topic", "brokers", "httpPort"):
        if k not in p:
            raise TemplateError(f"{params_path}: missing '{k}'")
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", p["appName"]):
        raise TemplateError("appName must be letters/digits/underscore and start with a letter")

    spec_path = os.path.join(base, p["swagger"])
    spec = read_spec(spec_path, p["operationId"])
    sheets = read_workbook(os.path.join(base, p["mappingWorkbook"]))
    req_fields = _top_fields(spec["request"])
    reply_fields = _top_fields(spec["reply"])

    event_rows, event_targets = [], set()
    for r in sheets["Event"]:
        v, extra = translate(r["rule"], r["type"], f"Event row {r['row']} ({r['target']})", req_fields, None)
        event_rows.append({"target": r["target"], "value": v, "extra": extra})
        event_targets.add(r["target"])
    if p["keyField"] not in event_targets:
        raise TemplateError(f"keyField '{p['keyField']}' is not a target on the Event sheet")

    reply_rows = []
    for r in sheets["Response"]:
        if r["target"].split(".")[0] not in reply_fields:
            raise TemplateError(f"Response row {r['row']}: '{r['target']}' is not in the API 2xx response "
                                f"(fields: {', '.join(sorted(reply_fields))})")
        v, extra = translate(r["rule"], r["type"], f"Response row {r['row']} ({r['target']})", req_fields,
                             event_targets)
        reply_rows.append({"target": r["target"], "value": v, "extra": extra})

    compact = lambda o: json.dumps(o, separators=(",", ":"))
    values = {
        "APP_NAME": p["appName"],
        "APP_DESCRIPTION": p["description"],
        "SPEC_NAME": p["appName"] + "Api",
        "SPEC_FILE": os.path.basename(spec_path),
        "TRIGGER": trigger_name(spec["title"]),
        "FLOW": f"{p['operationId']}_{spec['method']}",
        "HTTP_PORT": str(p["httpPort"]),
        "BROKERS": p["brokers"],
        "TOPIC": p["topic"],
        "EVENT_SCHEMA_NAME": p["eventSchemaName"],
        "EVENT_SCHEMA": compact(event_schema(sheets["Event"])),
        "KEY_FIELD": p["keyField"],
        "REPLY_SCHEMA": compact({"type": "object", "properties": {"body": spec["reply"]}}),
    }
    return {"values": values, "rows": {"EVENT_MAPPING": event_rows, "REPLY_MAPPING": reply_rows},
            "spec_path": spec_path, "spec": spec}


# --------------------------------------------------------------------------- history parsing

# Positional arity per fda task; the LAST positional is greedy (history joins argv with spaces).
ARITY = {"cp": 2, "csp": 2, "cas": 2, "cap": 3, "rap": 1, "cc": 2, "sa": 3, "ca": 4, "aa": 4, "cl": 3,
         "rl": 3, "sms": 2, "mm": 2, "rmm": 1, "cs": 2, "rs": 1, "cf": 2, "rf": 1, "ct": 3, "cth": 3,
         "wth": 2, "ai": 1, "ri": 1, "cat": 3, "us": 2, "ums": 2}
FLAGS = {"-f": 1, "--file": 1, "-H": 0, "--history": 0, "-j": 0, "--json": 0, "--force": 0, "--doNotLink": 0,
         "--specFile": 1, "-C": 1, "--connection": 1, "--configType": 1, "--json-schema": 1,
         "--jsonSchemaFile": 1, "--json-value-to-schema": 1, "--type": 1, "-ty": 1, "--jsonValue": 1, "-jv": 1,
         "--jsonValueFile": 1, "-jvf": 1, "--foreach": 1, "-fe": 1, "--as": 1, "--input": 1, "--output": 1,
         "--restResourcePath": 1, "--field": 1}


def parse_history_command(cmd):
    """Re-split a history entry (argv joined by spaces, quotes lost) into argv."""
    toks = ANSI.sub("", cmd).split(" ")
    task, toks = toks[0], toks[1:]
    n = ARITY.get(task)
    if n is None:
        raise TemplateError(f"harvest: no arity known for task '{task}' in: {cmd}")
    argv, i, pos = [task], 0, 0
    while i < len(toks):
        t = toks[i]
        if t in FLAGS:
            k = FLAGS[t]
            if k == 0:
                argv.append(t)
                i += 1
            else:  # flag value is greedy up to the next known flag
                j = i + 1
                while j < len(toks) and toks[j] not in FLAGS:
                    j += 1
                argv += [t, " ".join(toks[i + 1:j])]
                i = j
        elif pos < n - 1:
            argv.append(t)
            pos += 1
            i += 1
        else:  # last positional: greedy
            j = i
            while j < len(toks) and toks[j] not in FLAGS:
                j += 1
            argv.append(" ".join(toks[i:j]))
            pos += 1
            i = j
    return argv


def strip_file_flags(argv):
    out, i = [], 0
    while i < len(argv):
        if argv[i] in ("-f", "--file"):
            i += 2
        elif argv[i] in ("-H", "--history"):
            i += 1
        else:
            out.append(argv[i])
            i += 1
    return out


def shell_line(argv):
    return " ".join(shlex.quote(a) for a in argv)


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)
