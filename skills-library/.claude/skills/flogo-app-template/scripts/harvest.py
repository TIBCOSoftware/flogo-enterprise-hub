"""Harvest the fda commands recorded in a Flogo app's design history into a reusable template.

    python scripts/harvest.py --flogo <golden>/<App>.flogo \
                              --params <golden-inputs>/<app>.params.json \
                              --out templates/<pattern>.fdatemplate

What it does (no AI involved - same history in, same template out):
  1. reads .flogodesign/history/<app>/history.json (written by fda when history is on)
  2. re-splits every recorded command into argv (fda stores them space-joined, quotes lost)
  3. prepends the `cp` step (history starts from the created project)
  4. collapses repeated mapping commands into @foreach blocks fed by the mapping workbook
  5. replaces the golden app's concrete values (app name, topic, brokers, swagger, ...) with ${PARAMS}
"""
import argparse
import html
import json
import os
import re

import fdalib

# Mapping commands that repeat once per workbook row -> one @foreach block each.
BLOCKS = [
    ("EVENT_MAPPING", "mm", ".BuildEvent.input.input.mapping."),
    ("REPLY_MAPPING", "mm", ".ConfigureHTTPResponse.input.input.mapping.body."),
]
# Whole-argument parameters (values too long or too structured for literal matching).
ARG_RULES = [
    ("sms", "--json-schema", "EVENT_SCHEMA"),
    ("cs", 2, "REPLY_SCHEMA"),
]
# Order in which ${PARAMS} are matched inside the remaining arguments (longest literal first).
LITERAL_PARAMS = ["APP_DESCRIPTION", "APP_NAME", "SPEC_NAME", "SPEC_FILE", "TRIGGER", "FLOW",
                  "EVENT_SCHEMA_NAME", "KEY_FIELD", "TOPIC", "BROKERS", "HTTP_PORT"]
# The pattern's fixed names. A golden value that matches one of them (e.g. keyField "key", eventSchemaName
# "Event") would be parameterized there too, so the harvest refuses it: rename it in the golden app.
PATTERN_NAMES = ("StartActivity Log_API BuildEvent PublishEvent ConfigureHTTPResponse Return ReplyBody EventBus "
                 "HTTP.Port Kafka.EventBus.Brokers Event.Topic con_kafka kafka_producer mapper logReply "
                 "input output mapping body settings schemas trigger port brokers authMode key topic stringValue "
                 "fe_metadata None coerce.toString")


def block_of(argv):
    for name, task, marker in BLOCKS:
        if argv[0] == task and marker in argv[1]:
            return name, marker
    return None, None


def apply_arg_rules(argv):
    for task, where, param in ARG_RULES:
        if argv[0] != task:
            continue
        if isinstance(where, int) and len(argv) > where:
            argv[where] = "${%s}" % param
        elif isinstance(where, str) and where in argv:
            argv[argv.index(where) + 1] = "${%s}" % param
    return argv


def parameterize(argv, values):
    # Longest literal first. Empty literals (e.g. description "") are skipped: they would match everywhere.
    order = [k for k in sorted(LITERAL_PARAMS, key=lambda k: -len(values[k])) if values[k]]
    if not order:
        return list(argv)
    param_of = {}
    for k in order:
        param_of.setdefault(values[k], k)
    # One pass over each argument, so an inserted ${PARAM} is never matched again by a later literal.
    literal = re.compile(r"(?<![A-Za-z0-9])(" + "|".join(re.escape(values[k]) for k in order) + r")(?![A-Za-z0-9])")
    out = []
    for a in argv:
        if (a.startswith("${") and a.endswith("}")) or re.fullmatch(r"[A-Za-z0-9+/]{40,}={0,2}", a):
            out.append(a)  # already a parameter, or an opaque base64 blob (flow layout)
            continue
        out.append(literal.sub(lambda m: "${%s}" % param_of[m.group(1)], a))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--flogo", required=True, help="golden .flogo built with fda history enabled")
    ap.add_argument("--params", required=True, help="params.json describing the golden app's concrete values")
    ap.add_argument("--out", required=True, help="template file to write")
    a = ap.parse_args()
    fdalib.utf8_console()

    flogo = os.path.abspath(a.flogo)
    app = os.path.splitext(os.path.basename(flogo))[0]
    hist_dir = os.path.join(os.path.dirname(flogo), ".flogodesign", "history", app)
    hist_file = os.path.join(hist_dir, "history.json")
    if not os.path.exists(hist_file):
        fdalib.die(f"no fda history at {hist_file} - build the golden app with FLOGO_DESIGN_ENABLE_HISTORY=true")

    values = fdalib.derive(a.params)["values"]
    for k in LITERAL_PARAMS:
        if k != "APP_DESCRIPTION" and values[k] and re.search(
                r"(?<![A-Za-z0-9])" + re.escape(values[k]) + r"(?![A-Za-z0-9])", PATTERN_NAMES):
            fdalib.die(f"golden {k} '{values[k]}' is also one of the pattern's fixed names, so it can't be "
                       "parameterized safely - give it a more specific value in the golden app and harvest again")
    initial = json.load(open(os.path.join(hist_dir, f"0_{app}.initial.flogo"), encoding="utf-8"))
    # `cp` is not recorded, so it is written here. Its arguments are the app name and description: emit those
    # parameters explicitly, so an empty description still becomes ${APP_DESCRIPTION} (parameterize skips "").
    # fda stores the description HTML-escaped (R&D -> R&amp;D), so compare it unescaped.
    name, desc = initial["name"], html.unescape(initial.get("description", ""))
    commands = [["cp", "${APP_NAME}" if name == values["APP_NAME"] else name,
                 "${APP_DESCRIPTION}" if desc == values["APP_DESCRIPTION"] else desc]]
    for c in json.load(open(hist_file, encoding="utf-8"))["commands"][1:]:
        commands.append(fdalib.strip_file_flags(fdalib.parse_history_command(c["fdaCommand"])))

    lines, counts, used = [], {"steps": len(commands), "blocks": 0, "rows": 0}, set()
    prev_block = None
    for argv in commands:
        name, marker = block_of(argv)
        if name:
            counts["rows"] += 1
            if name == prev_block:
                continue
            prefix = parameterize([argv[1].split(marker)[0]], values)[0]
            lines.append(f"@foreach {name}")
            lines.append(fdalib.shell_line([argv[0], prefix + marker + "${target}", "${value}"]))
            lines.append("@end")
            counts["blocks"] += 1
            prev_block = name
            continue
        prev_block = None
        argv = parameterize(apply_arg_rules(list(argv)), values)
        lines.append(fdalib.shell_line(argv))

    for l in lines:
        used.update(re.findall(r"\$\{([A-Z_]+)\}", l))
    header = [
        "# Flogo app template: REST (OpenAPI) -> canonical event mapper -> Kafka, HTTP 202 reply",
        f"# Harvested from the fda design history of {app} ({counts['steps']} recorded steps).",
        "# One fda command per line (-f <app>.flogo is added by generate_app.py).",
        "# Parameters: " + " ".join(sorted(used)),
        "# @foreach EVENT_MAPPING = Event sheet rows, @foreach REPLY_MAPPING = Response sheet rows",
        "",
    ]
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(header + lines) + "\n")

    print(f"Harvested {counts['steps']} fda steps from {app}")
    print(f"  {counts['rows']} mapping commands collapsed into {counts['blocks']} @foreach blocks")
    print(f"  {len(used)} parameters: {', '.join(sorted(used))}")
    print(f"  template: {fdalib.rel(a.out)} ({len(lines)} lines)")


if __name__ == "__main__":
    try:
        main()
    except fdalib.TemplateError as e:
        fdalib.die(str(e))
