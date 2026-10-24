#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# HOW THIS BUILDS THE APP: this script generates the .flogo application with the
# TIBCO Flogo Design CLI (fda / flogodesign-cli), driven programmatically through
# the App wrapper in fda_common.py. It issues fda subcommands (create the app,
# triggers, flows and activities; set schemas, connections, app properties and
# mappings) to build the app deterministically -- it does NOT hand-write the .flogo
# JSON. (The one exception, noted inline where it applies, is the RAG sample, which
# transplants one openAI vector-search activity from a donor app because fda has no
# recipe for user-extension activities.)
# ---------------------------------------------------------------------------
"""Build RetailBankingSecureMCPServer.flogo with fda only (governed: scoped reads + guarded writes, JWT sign-in).
Kestrel Bank retail banking assistant - 19 PostgreSQL-backed MCP tools from tool_spec.py (14 customer tools, whoami,
find_branch and 3 reviewer tools for the human-in-the-loop decision; one server, the role is checked in SQL on every call).

Authentication: the MCP Server trigger uses Authentication Type "JWT Token" (HS256, secret in the MCP.JWT_Secret app
property) and every tool handler requires ONE scope (tool_spec "scope"): a token without that scope never sees the tool
in tools/list and cannot call it. Each handler hands the flow the verified claims (`tokenInfo`, next to `arguments`), and
every SQL parameter whose tool_spec source is SUB ("@sub") is mapped to $flow.tokenInfo.sub - so the caller's identity
is never a tool argument and never model input.

Every tool flow is   [GuardedWrite (#insert ... SELECT * FROM rule_fn)] -> ReadOutcome (#query) -> Return,
and Return hands ALL readback rows to the MCP caller as {"records":[...]}.

The email tool is special: GuardedWrite logs the request only when the SQL authorises it (email_log), ReadOutcome is the
SQL-validated payload (email_confirmation_payload) and a conditional branch sends the email ONLY when the SQL says
send_status == "SEND":
    ReadOutcome --(send_status == "SEND")--> SendMail --> Return
    ReadOutcome --(otherwise)----------------------------> ReturnNotSent
Both returns hand back the same readback row. The recipient is the To_Email app property (the configured ops inbox)
and the sender is Email_Username, the account that signs in to SMTP (servers reject other From addresses);
the SQL decides the content and the reported outcome, so an unauthorised call sends nothing and carries no account data.

Re-run:  python _rebuild/build_mcp.py      (needs the banking_jwt_auth DB; OUT_DIR=<empty dir> to replay; refuses to overwrite).
JWT secret: env JWT_SECRET is written into MCP.JWT_Secret when set (a local build - scrub before sharing); otherwise the
placeholder SET_YOUR_JWT_SECRET is written. The value is never printed.
Chunked build (keeps each run short): BUILD_TO=<n> builds the project + the first n tools; RESUME_FROM=<n> continues on
the existing file from tool n (0-based). On a mid-run failure, delete ONLY RetailBankingSecureMCPServer.flogo and re-run.
Add tools to an EXISTING app (e.g. a new tool after a designer edit, without regenerating anything else):
  ADD_TOOLS=whoami APP_FILE=<path>.flogo python _rebuild/build_mcp.py"""
import json, os, subprocess
os.environ.setdefault("PG_DB", "banking_jwt_auth")
from fda_common import App, CFG, FDA, USE_CASE_DIR, jtmp, result_columns, setting
from tool_spec import TOOLS, param_source

APP_FILE_NAME = "RetailBankingSecureMCPServer.flogo"
TRIG, PORT, ENDPOINT, SERVER_NAME = "RetailBankingSecureMCPServer", "9972", "/retail-banking-mcp", "RetailBankingSecure"
JWT_PLACEHOLDER = "SET_YOUR_JWT_SECRET"

# The verified-claims object the MCP Server trigger hands each tool flow (JWT Token / OAuth 2.0 auth).
TOKEN_INFO = {"scopes": {"type": "array", "items": {"type": "string"}}, "expiration": {"type": "number"},
              "iss": {"type": "string"}, "sub": {"type": "string"}, "aud": {"type": "array", "items": {"type": "string"}},
              "name": {"type": "string"}, "email": {"type": "string"}}
SEND_COND = '$activity[ReadOutcome].Output.records[0].send_status == "SEND"'
# The #sendmail Password field is password-typed: the designer derives that from a SECRET: prefix, so a plain string
# property fails validation (wrongTypeProp). fda cannot SECRET-encrypt, so: use a SECRET: value from env if there is
# one, else a portable dummy blob (re-enter the app password in the designer's App Properties for live sending).
DUMMY_SECRET = "SECRET:0llnwBzNtMzA8d+RYoqdf9o6EuE="


def email_settings():
    """config.md "Email Server, Username and app password" section; env wins."""
    user = setting("EMAIL_USERNAME", "Username")
    pw = os.environ.get("EMAIL_PASSWORD") or ""
    pw, src = ((pw, "SECRET: value from env EMAIL_PASSWORD") if pw.startswith("SECRET:")
               else (DUMMY_SECRET, "portable dummy SECRET: blob - re-enter the app password in App Properties"))
    return {"user": user, "to": os.environ.get("TO_EMAIL") or user, "password": pw, "password_src": src,
            "host": os.environ.get("SMTP_HOST") or CFG.get("Server") or "smtp.gmail.com",
            "port": os.environ.get("SMTP_PORT") or CFG.get("Port") or "465"}


def sendmail_input(em):
    return {"Server": em["host"], "Port": int(em["port"]), "authorizationType": "Basic",
            "Username": '=$property["Email_Username"]', "Password": '=$property["Email_App_Password"]',
            "authorizationConn": "", "Connection Security": "SSL", "serverCertificate": "",
            "message_content_type": "text/plain",
            "sender": '=$property["Email_Username"]', "recipients": '=$property["To_Email"]',
            "cc_recipients": "", "bcc_recipients": "", "reply_to": '=$property["Email_Username"]',
            "subject": '=$activity[ReadOutcome].Output.records[0].subject',
            "message": '=$activity[ReadOutcome].Output.records[0].body'}


def existing_app(path):
    """An App wrapper on a file that already exists (App() refuses to touch existing files)."""
    app = App.__new__(App)
    app.file = os.path.abspath(path)
    return app


def build_project(app, em):
    f = app.fda
    print("== project + PostgreSQL ==")
    f("cp", TRIG, "Kestrel Bank Retail Banking Assistant secure MCP Server - JWT sign-in with per-tool scopes, scoped reads, "
                  "guarded writes, scam-protected payments and the reviewer loop")
    app.postgres_connection()
    f("cap", "MCP_SERVER_PORT", "string", PORT)
    jwt = os.environ.get("JWT_SECRET")
    f("cap", "MCP.JWT_Secret", "string", jwt or JWT_PLACEHOLDER)
    print("JWT secret source:", "env JWT_SECRET (local build - scrub before sharing)" if jwt else "placeholder " + JWT_PLACEHOLDER)
    # email properties (used only by the email tool; scrub before publishing)
    f("cap", "Email_Username", "string", em["user"])
    f("cap", "Email_App_Password", "string", em["password"])
    f("cap", "To_Email", "string", em["to"])

    print("== trigger (JWT Token auth) ==")
    f("ct", TRIG, "tr_mcpserver", "Kestrel Bank Retail Banking secure MCP server - JWT authenticated, per-tool scopes")
    f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
    f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
    f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", ENDPOINT)
    f("sa", "trigger", f"{TRIG}.settings.serverName", SERVER_NAME)
    f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
    f("sa", "trigger", f"{TRIG}.settings.authType", "JWT Token")
    f("sa", "trigger", f"{TRIG}.settings.authToken", "MCP.JWT_Secret", "-C", "app-property")
    f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')


def flow_links(app, flow):
    return next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)["data"]["links"]


def link_index(app, flow, src, dst):
    return next(i for i, l in enumerate(flow_links(app, flow)) if l["from"] == src and l["to"] == dst)


def branch_email(app, flow):
    """ReadOutcome --(send_status == "SEND")--> SendMail --> Return ;  ReadOutcome --(otherwise)--> ReturnNotSent."""
    f = app.fda
    i = link_index(app, flow, "ReadOutcome", "SendMail")
    f("sa", "flow", f"{flow}.links[{i}].type", "expression")
    f("sa", "flow", f"{flow}.links[{i}].value", SEND_COND, "--force")     # no leading '=' on link conditions
    f("sa", "flow", f"{flow}.links[{i}].label", "send_status is SEND")
    f("cl", flow, "ReadOutcome", "ReturnNotSent")
    j = link_index(app, flow, "ReadOutcome", "ReturnNotSent")
    f("sa", "flow", f"{flow}.links[{j}].type", "exprOtherwise")
    f("sa", "flow", f"{flow}.links[{j}].label", "otherwise (NOT_SENT)")
    links = flow_links(app, flow)
    if links[i].get("type") != "expression" or links[i].get("value") != SEND_COND or links[j].get("type") != "exprOtherwise":
        raise SystemExit(f"FAILED: email branch links not set as expected: {links}")
    if not any(l["from"] == "SendMail" and l["to"] == "Return" for l in links):
        raise SystemExit(f"FAILED: SendMail -> Return link missing: {links}")


def build_tool(app, t, trig=TRIG, em=None):
    """One tool: flow + PostgreSQL activities + MCP handler (scope, arguments + tokenInfo) + flow metadata."""
    f = app.fda
    flow, tool = t["flow"], t["tool"]
    print(f"== tool {tool} (scope {t['scope']}) ==")
    f("cf", flow, t["desc"])
    if "write" in t:
        f("ca", flow, "GuardedWrite", "act_postgresql_insert", "PostgreSQL Insert", "-C", "PostgresConn")
    f("ca", flow, "ReadOutcome", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
    if t.get("email"):
        f("ca", flow, "SendMail", "act_general_sendmail", "Send confirmation email")
    f("ca", flow, "Return", "act_default_actreturn", "Simple Return")
    if t.get("email"):
        f("ca", flow, "ReturnNotSent", "act_default_actreturn", "Return without sending", "--doNotLink")
    # parameter sources: tool arguments -> $flow.arguments.<a>; SUB ("@sub") -> $flow.tokenInfo.sub (the verified caller)
    if "write" in t:
        sql, params = t["write"]
        app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", sql, [(p, param_source(s)) for p, s in params])
    sql, params = t["read"]
    app.bake_pg(flow, "ReadOutcome", "act_postgresql_query", sql, [(p, param_source(s)) for p, s in params],
                result_columns(sql))
    if t.get("email"):
        f("sa", "activity", f"{flow}.SendMail.input", "--jsonFile", jtmp(sendmail_input(em or email_settings())), "--force")
        branch_email(app, flow)

    f("cth", flow, trig, t["desc"], "--mcpHandlerType", "Tool", "--mcpHandlerName", tool, "--mcpHandlerDescription", t["desc"])
    f("wth", flow, f"{trig}.{flow}", "--force")
    # second pass adds tokenInfo to the handler -> flow mapping (inputs only, so the reply wiring is untouched)
    f("wth", flow, f"{trig}.{flow}", "--force", "--input", "arguments:object,tokenInfo:object", "--inputs-only")
    props = {a: {"type": "string", "description": d} for a, d in t["args"]}
    req = [a for a, _ in t["args"]]
    f("cs", f"{tool}_Args", json.dumps({"type": "object", "properties": props, "required": req}))
    f("sa", "handler", f"{trig}.{flow}.schemas.output.arguments", f"{tool}_Args", "-C", "schema", "--force")
    f("sa", "handler", f"{trig}.{flow}.schemas.reply.response", "ToolResponse", "-C", "schema", "--force")
    f("sa", "handler", f"{trig}.{flow}.settings.scope", t["scope"])            # the ONE scope this tool requires
    # MCP hints must be real JSON booleans (--type boolean stores the string "true")
    f("sa", "handler", f"{trig}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{trig}.{flow}.settings.destructiveToolHint", "--jsonValue", str(t.get("destructive", False)).lower())
    f("sa", "handler", f"{trig}.{flow}.settings.idempotentToolHint", "--jsonValue", str(t.get("idempotent", True)).lower())
    f("sa", "handler", f"{trig}.{flow}.settings.openWorldToolHint", "--jsonValue", "false")

    # flow metadata + fe_metadata so $flow.arguments.<x> and $flow.tokenInfo.sub resolve in the designer without a Sync
    compact = json.dumps({a: {"type": "string"} for a, _ in t["args"]})
    resp = '{"data":{"type":"string"},"error":{"type":"string"}}'
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile", jtmp([
        {"name": "arguments", "type": "object", "schema": {"type": "json", "value": compact}},
        {"name": "tokenInfo", "type": "object", "schema": {"type": "json", "value": json.dumps(TOKEN_INFO)}}]), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile",
      jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": resp}}]), "--force")
    fe_in = {"type": "object", "title": trig, "properties": {
        "arguments": {"type": "object", "properties": props, "required": req},
        "tokenInfo": {"type": "object", "properties": TOKEN_INFO}}}
    fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": json.loads(resp)}},
              "required": ["response"]}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

    # all readback rows go back to the caller (several tools return many rows)
    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")
    if t.get("email"):
        f("mm", f"{flow}.ReturnNotSent.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")


def main():
    print("fda:", FDA)
    print(subprocess.run([FDA, "version"], capture_output=True, text=True).stdout.strip())
    add = [x for x in os.environ.get("ADD_TOOLS", "").split(",") if x]
    if add:                                              # patch an existing app: add only these tools
        app = existing_app(os.environ.get("APP_FILE") or os.path.join(USE_CASE_DIR, APP_FILE_NAME))
        trig = app.load()["triggers"][0]["id"]
        by_name = {t["tool"]: t for t in TOOLS}
        for name in add:
            build_tool(app, by_name[name], trig)
        print("\nadded", add, "to", app.file)
        return
    resume = int(os.environ.get("RESUME_FROM", "0"))
    build_to = int(os.environ.get("BUILD_TO", str(len(TOOLS))))
    em = email_settings()
    print("email password source:", em["password_src"])          # never the value itself
    if resume:
        app = existing_app(os.path.join(os.environ.get("OUT_DIR") or USE_CASE_DIR, APP_FILE_NAME))
    else:
        app = App(APP_FILE_NAME, os.environ.get("OUT_DIR"))
        build_project(app, em)
    for t in TOOLS[resume:build_to]:
        build_tool(app, t, TRIG, em)
    print(f"\nMCP server build {'complete' if build_to >= len(TOOLS) else 'paused after tool ' + str(build_to)}:", app.file)


if __name__ == "__main__":
    main()
