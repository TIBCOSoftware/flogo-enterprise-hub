#!/usr/bin/env python3
"""Build BankOpsMCPServer.flogo with fda only.

JWT Token auth on the MCP Server trigger + a required `scope` per tool: a token without the scope never sees
the tool. Each tool flow takes the agent's privilege ID from the verified token ($flow.tokenInfo.sub), audits
the call, and lets the agent registry in PostgreSQL decide (status, expiry, entitlement).

Re-run:  python _rebuild/build_mcp.py      (needs bankops_agents loaded; OUT_DIR=<empty dir> to replay)
Secrets are read at run time: PG password from env/config.md, the JWT signing secret from env JWT_SECRET."""
import json, os, sys
from fda_common import App, jtmp, result_columns
from tool_spec import TOOLS, TOKEN_SOURCES

JWT_SECRET = os.environ.get("JWT_SECRET") or sys.exit("set JWT_SECRET (the HS256 secret the agent tokens are signed with)")
app = App("BankOpsMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT = "BankOpsMCPServer", "9871", "/bankops-mcp"

TOKEN_INFO = {"scopes": {"type": "array", "items": {"type": "string"}}, "expiration": {"type": "number"},
              "iss": {"type": "string"}, "sub": {"type": "string"}, "aud": {"type": "array", "items": {"type": "string"}},
              "name": {"type": "string"}, "email": {"type": "string"}}

print("== project + PostgreSQL ==")
f("cp", "BankOpsMCPServer", "Harbor Bank back-office MCP server - every agent has its own privilege ID (JWT sub + scopes)")
app.postgres_connection()
f("cap", "MCP_SERVER_PORT", "string", PORT)
f("cap", "MCP.JWT_Secret", "string", JWT_SECRET)

print("== trigger (JWT Token auth) ==")
f("ct", TRIG, "tr_mcpserver", "BankOps MCP server - JWT authenticated")
f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", ENDPOINT)
f("sa", "trigger", f"{TRIG}.settings.serverName", "BankOpsMCPServer")
f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
f("sa", "trigger", f"{TRIG}.settings.authType", "JWT Token")
f("sa", "trigger", f"{TRIG}.settings.authToken", "MCP.JWT_Secret", "-C", "app-property")
f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')

def src(s): return TOKEN_SOURCES.get(s) or f"=$flow.arguments.{s}"

for t in TOOLS:
    flow, tool = t["flow"], t["tool"]
    print(f"== tool {tool} (scope: {t['scope'] or 'any authenticated agent'}) ==")
    f("cf", flow, t["desc"])
    f("ca", flow, "GuardedWrite", "act_postgresql_insert", "PostgreSQL Insert", "-C", "PostgresConn")
    f("ca", flow, "ReadOutcome", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
    f("ca", flow, "Return", "act_default_actreturn", "Simple Return")
    sql, params = t["write"]
    app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", sql, [(p, src(s)) for p, s in params])
    sql, params = t["read"]
    app.bake_pg(flow, "ReadOutcome", "act_postgresql_query", sql, [(p, src(s)) for p, s in params], result_columns(sql))

    f("cth", flow, TRIG, t["desc"], "--mcpHandlerType", "Tool", "--mcpHandlerName", tool, "--mcpHandlerDescription", t["desc"])
    f("wth", flow, f"{TRIG}.{flow}", "--force")
    # second pass adds tokenInfo to the handler -> flow mapping (inputs only, so the reply wiring is untouched)
    f("wth", flow, f"{TRIG}.{flow}", "--force", "--input", "arguments:object,tokenInfo:object", "--inputs-only")
    props = {a: {"type": "string", "description": d} for a, d in t["args"]}
    req = [a for a, _ in t["args"]]
    f("cs", f"{tool}_Args", json.dumps({"type": "object", "properties": props, "required": req}))
    f("sa", "handler", f"{TRIG}.{flow}.schemas.output.arguments", f"{tool}_Args", "-C", "schema", "--force")
    f("sa", "handler", f"{TRIG}.{flow}.schemas.reply.response", "ToolResponse", "-C", "schema", "--force")
    if t["scope"]:
        f("sa", "handler", f"{TRIG}.{flow}.settings.scope", t["scope"])
    f("sa", "handler", f"{TRIG}.{flow}.settings.toolTitle", tool.replace("_", " ").title())
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", str(t.get("destructive", False)).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.idempotentToolHint", "--jsonValue", str(t.get("idempotent", True)).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.openWorldToolHint", "--jsonValue", "false")

    # flow metadata + fe_metadata so $flow.arguments.<x> and $flow.tokenInfo.sub resolve in the designer without a Sync
    compact = json.dumps({a: {"type": "string"} for a, _ in t["args"]})
    resp = '{"data":{"type":"string"},"error":{"type":"string"}}'
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile", jtmp([
        {"name": "arguments", "type": "object", "schema": {"type": "json", "value": compact}},
        {"name": "tokenInfo", "type": "object", "schema": {"type": "json", "value": json.dumps(TOKEN_INFO)}}]), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile",
      jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": resp}}]), "--force")
    fe_in = {"type": "object", "title": TRIG, "properties": {
        "arguments": {"type": "object", "properties": props, "required": req},
        "tokenInfo": {"type": "object", "properties": TOKEN_INFO}}}
    fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": json.loads(resp)}},
              "required": ["response"]}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")

print("\nMCP server build complete:", app.file)
