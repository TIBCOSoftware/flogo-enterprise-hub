#!/usr/bin/env python3
"""Build PassengerServicesMCPServer.flogo with fda only (governed: scoped reads + guarded writes).
The email tool is special: it reads a SQL-validated payload, then sends to the configured ops inbox
(recipient = To_Email app property, exactly like the original airline sample); the SQL decides the content
and the reported outcome, so an unauthorised call carries no booking details.
Re-run:  python _rebuild/build_mcp.py      (needs the airline_governed DB; OUT_DIR=<empty dir> to replay)."""
import json, os
from fda_common import App, jtmp, result_columns, setting
from tool_spec import TOOLS

app = App("PassengerServicesMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT = "PassengerServicesMCPServer", "9852", "/passenger-services-gov-mcp"

EMAIL_USER = setting("EMAIL_USERNAME", "Username")
EMAIL_PASS = setting("EMAIL_PASSWORD", "Password")
EMAIL_TO   = os.environ.get("TO_EMAIL") or EMAIL_USER
SMTP_HOST  = os.environ.get("SMTP_HOST") or "smtp.gmail.com"
SMTP_PORT  = os.environ.get("SMTP_PORT") or "465"

print("== project + PostgreSQL ==")
f("cp", TRIG, "Meridian Passenger Services (governed) MCP Server - scoped reads and guarded writes for verified travellers")
app.postgres_connection()
f("cap", "MCP_SERVER_PORT", "string", PORT)
# email properties (used only by the email tool; password is scrubbed to a placeholder before publishing)
f("cap", "Email_Username", "string", EMAIL_USER)
f("cap", "Email_App_Password", "string", EMAIL_PASS)
f("cap", "To_Email", "string", EMAIL_TO)

print("== trigger ==")
f("ct", TRIG, "tr_mcpserver", "Meridian Passenger Services governed MCP server")
f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", ENDPOINT)
f("sa", "trigger", f"{TRIG}.settings.serverName", TRIG)
f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')

def sendmail_input():
    return {"Server": SMTP_HOST, "Port": int(SMTP_PORT), "authorizationType": "Basic",
            "Username": '=$property["Email_Username"]', "Password": '=$property["Email_App_Password"]',
            "authorizationConn": "", "Connection Security": "SSL", "serverCertificate": "",
            "message_content_type": "text/plain",
            "sender": '=$property["To_Email"]', "recipients": '=$property["To_Email"]',
            "cc_recipients": "", "bcc_recipients": "", "reply_to": '=$property["Email_Username"]',
            "subject": '=$activity[ReadOutcome].Output.records[0].subject',
            "message": '=$activity[ReadOutcome].Output.records[0].body'}

for t in TOOLS:
    flow, tool = t["flow"], t["tool"]
    print(f"== tool {tool} ==")
    f("cf", flow, t["desc"])
    if "write" in t:
        f("ca", flow, "GuardedWrite", "act_postgresql_insert", "PostgreSQL Insert", "-C", "PostgresConn")
    f("ca", flow, "ReadOutcome", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
    if t.get("email"):
        f("ca", flow, "SendMail", "act_general_sendmail", "Send confirmation email")
    f("ca", flow, "Return", "act_default_actreturn", "Simple Return")
    arg = lambda a: f"=$flow.arguments.{a}"
    if "write" in t:
        sql, params = t["write"]
        app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", sql, [(p, arg(a)) for p, a in params])
    sql, params = t["read"]
    app.bake_pg(flow, "ReadOutcome", "act_postgresql_query", sql, [(p, arg(a)) for p, a in params], result_columns(sql))
    if t.get("email"):
        f("sa", "activity", f"{flow}.SendMail.input", "--jsonFile", jtmp(sendmail_input()), "--force")

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
