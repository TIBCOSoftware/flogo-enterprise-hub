#!/usr/bin/env python3
"""Build AuthorServicesMCPServer.flogo with fda only (governed pattern: scoped reads + guarded writes).
Re-run:  python _rebuild/build_mcp.py      (needs the author_services DB loaded; OUT_DIR=<empty dir> to replay)
Secrets are read at run time from env or config.md - see fda_common.py."""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import TOOLS

app = App("AuthorServicesMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT = "AuthorServicesMCPServer", "9842", "/author-services-mcp"

print("== project + PostgreSQL ==")
f("cp", "AuthorServicesMCPServer", "Author Services MCP Server - scoped reads and guarded writes for verified authors")
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

for t in TOOLS:
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
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", "false")
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

    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")

print("\nMCP server build complete:", app.file)
