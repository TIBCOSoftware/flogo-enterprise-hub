#!/usr/bin/env python3
"""Build AuthorServicesMCPServer.flogo with fda only (governed pattern: scoped reads + guarded writes).
14 PostgreSQL-backed MCP tools from tool_spec.py: 10 author tools + 4 reviewer tools for the human-in-the-loop decision
(one server; the role is checked in SQL on every call).

Every tool flow is   [GuardedWrite (#insert ... SELECT * FROM rule_fn)] -> ReadOutcome (#query) -> Return,
and Return hands ALL readback rows to the MCP caller as {"records":[...]}.

Re-run:  python _rebuild/build_mcp.py      (needs the author_services DB loaded; OUT_DIR=<empty dir> to replay;
refuses to overwrite). Chunked build (keeps each run short): BUILD_TO=<n> builds the project + the first n tools;
RESUME_FROM=<n> continues on the existing file from tool n (0-based). On a mid-run failure, delete ONLY
AuthorServicesMCPServer.flogo and re-run. Secrets are read at run time from env or config.md - see fda_common.py."""
import json, os, subprocess
os.environ.setdefault("PG_DB", "author_services")
from fda_common import App, FDA, USE_CASE_DIR, jtmp, result_columns
from tool_spec import TOOLS

RESUME_FROM = int(os.environ.get("RESUME_FROM", "0"))
BUILD_TO = int(os.environ.get("BUILD_TO", str(len(TOOLS))))
if RESUME_FROM:
    import fda_common
    fda_common.App.__init__ = lambda self, filename, out_dir=None: setattr(
        self, "file", os.path.join(out_dir or USE_CASE_DIR, filename))
app = App("AuthorServicesMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT = "AuthorServicesMCPServer", "9842", "/author-services-mcp"

print("fda:", FDA)
print(subprocess.run([FDA, "version"], capture_output=True, text=True).stdout.strip())

if not RESUME_FROM:
    print("== project + PostgreSQL ==")
    f("cp", "AuthorServicesMCPServer", "Author Services MCP Server - scoped reads, guarded writes, submission checks and the reviewer loop")
    app.postgres_connection()
    f("cap", "MCP_SERVER_PORT", "string", PORT)

    print("== trigger ==")
    f("ct", TRIG, "tr_mcpserver", "Author Services MCP server")
    f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
    f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
    f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", ENDPOINT)
    f("sa", "trigger", f"{TRIG}.settings.serverName", "AuthorServicesMCPServer")
    f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
    f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')

for t in TOOLS[RESUME_FROM:BUILD_TO]:
    flow, tool = t["flow"], t["tool"]
    print(f"== tool {tool} ==")
    f("cf", flow, t["desc"])
    if "write" in t:
        f("ca", flow, "GuardedWrite", "act_postgresql_insert", "PostgreSQL Insert", "-C", "PostgresConn")
    f("ca", flow, "ReadOutcome", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
    f("ca", flow, "Return", "act_default_actreturn", "Simple Return")
    arg = lambda a: f"=$flow.arguments.{a}"
    if "write" in t:
        sql, params = t["write"]
        app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", sql, [(p, arg(a)) for p, a in params])
    sql, params = t["read"]
    app.bake_pg(flow, "ReadOutcome", "act_postgresql_query", sql, [(p, arg(a)) for p, a in params], result_columns(sql))

    f("cth", flow, TRIG, t["desc"], "--mcpHandlerType", "Tool", "--mcpHandlerName", tool, "--mcpHandlerDescription", t["desc"])
    f("wth", flow, f"{TRIG}.{flow}", "--force")
    props = {a: {"type": "string", "description": d} for a, d in t["args"]}
    req = [a for a, _ in t["args"]]
    f("cs", f"{tool}_Args", json.dumps({"type": "object", "properties": props, "required": req}))
    f("sa", "handler", f"{TRIG}.{flow}.schemas.output.arguments", f"{tool}_Args", "-C", "schema", "--force")
    f("sa", "handler", f"{TRIG}.{flow}.schemas.reply.response", "ToolResponse", "-C", "schema", "--force")
    # MCP hints must be real JSON booleans (--type boolean stores the string "true")
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", str(t.get("destructive", False)).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.idempotentToolHint", "--jsonValue", str(t.get("idempotent", True)).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.openWorldToolHint", "--jsonValue", "false")

    # flow metadata + fe_metadata so $flow.arguments.<x> resolves in the designer without a Sync
    compact = json.dumps({a: {"type": "string"} for a, _ in t["args"]})
    resp = '{"data":{"type":"string"},"error":{"type":"string"}}'
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile",
      jtmp([{"name": "arguments", "type": "object", "schema": {"type": "json", "value": compact}}]), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile",
      jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": resp}}]), "--force")
    fe_in = {"type": "object", "title": TRIG, "properties": {"arguments": {"type": "object", "properties": props, "required": req}}}
    fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": json.loads(resp)}}, "required": ["response"]}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

    # all readback rows go back to the caller (several tools return many rows)
    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")

print(f"\nMCP server build {'complete' if BUILD_TO >= len(TOOLS) else 'paused after tool ' + str(BUILD_TO)}:", app.file)
