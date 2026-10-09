#!/usr/bin/env python3
"""Build BankOpsSpecialists.flogo with fda only: specialist AI agents exposed as MCP tools.

  MCP Server trigger, JWT Token auth (SPECIALISTS_JWT_SECRET), one required scope per specialist tool.
  Each tool flow:  GuardedWrite  - audit the delegation under the CALLER's privilege ID ($flow.tokenInfo.sub)
                   GateCheck     - the bank registry decides (status, expiry, entitlement) -> ALLOWED / DENIED
                   ALLOWED  ->   specialist AI Agent (its OWN bank-MCP JWT) -> ReturnOK (the agent's answer)
                   DENIED   ->   ReturnDenied ("DELEGATION_REFUSED: <reason>") - the specialist never runs
Agent-to-agent with real token validation and caller identity, instead of fixed-token A2A.

Re-run:  python orchestrated/_rebuild/build_specialists.py   (OUT_DIR=<empty dir> to replay)
Needs: bankops_agents loaded; env SPECIALISTS_JWT_SECRET, JWT_SECRET (bank tokens are minted from it), LLM_MODEL."""
import json, os
from orch_common import (ORCH_DIR, BANK_MCP_URL, SPECIALISTS_PORT, SPECIALISTS_PATH, SPECIALISTS, secret)
from fda_common import App, jtmp, result_columns
from mint_agent_tokens import mint

app = App("BankOpsSpecialists.flogo", os.environ.get("OUT_DIR") or ORCH_DIR)
f = app.fda
TRIG = "BankOpsSpecialists"
TOKEN_INFO = {"scopes": {"type": "array", "items": {"type": "string"}}, "expiration": {"type": "number"},
              "iss": {"type": "string"}, "sub": {"type": "string"}, "aud": {"type": "array", "items": {"type": "string"}},
              "name": {"type": "string"}, "email": {"type": "string"}}
HDR = [("request", "The staff member's request in full, in plain words, including account ids, card details and the reason")]

print("== project + connections ==")
f("cp", "BankOpsSpecialists", "Harbor Bank specialist AI agents exposed as JWT-protected MCP tools (orchestrated variant)")
# LLM connection FIRST: fda rebinds the AI Agent's llmProviderConnection to the first connection in the file on
# save, so that must be the LLM provider (the PostgreSQL activities are bound explicitly and verified by bake_pg).
app.llm_connection()
app.postgres_connection()
f("cap", "MCP_SERVER_PORT", "string", SPECIALISTS_PORT)
f("cap", "MCP.JWT_Secret", "string", secret("SPECIALISTS_JWT_SECRET"))
bank_secret = secret("JWT_SECRET")
for sp in SPECIALISTS:
    f("cap", sp["prop"], "string", os.environ.get(sp["prop"].replace(".", "_").upper()) or mint(sp["agent"], bank_secret))
    f("cc", sp["conn"], "con_mcpserverconfig")
    f("sa", "connection", f"{sp['conn']}.settings.serverType", "http")
    f("sa", "connection", f"{sp['conn']}.settings.serverUrl", BANK_MCP_URL)
    f("sa", "connection", f"{sp['conn']}.settings.httpTransportType", "streamable")
    f("sa", "connection", f"{sp['conn']}.settings.authType", "Token")
    f("sa", "connection", f"{sp['conn']}.settings.authToken", sp["prop"], "-C", "app-property")

print("== trigger (JWT Token auth) ==")
f("ct", TRIG, "tr_mcpserver", "Specialist agents as MCP tools - JWT authenticated")
f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", SPECIALISTS_PATH)
f("sa", "trigger", f"{TRIG}.settings.serverName", "BankOpsSpecialists")
f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
f("sa", "trigger", f"{TRIG}.settings.authType", "JWT Token")
f("sa", "trigger", f"{TRIG}.settings.authToken", "MCP.JWT_Secret", "-C", "app-property")
f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')

for sp in SPECIALISTS:
    flow, tool, act = sp["flow"], sp["tool"], sp["act"]
    print(f"== specialist tool {tool} (scope {sp['scope']}) ==")
    f("cf", flow, sp["desc"])
    f("ca", flow, "GuardedWrite", "act_postgresql_insert", "Audit the delegation", "-C", "PostgresConn")
    f("ca", flow, "GateCheck", "act_postgresql_query", "Registry decides", "-C", "PostgresConn")
    f("ca", flow, act, "act_agenticai_agentactivity", sp["agent"])
    f("ca", flow, "ReturnOK", "act_default_actreturn", "Specialist answer")
    f("ca", flow, "ReturnDenied", "act_default_actreturn", "Delegation refused", "--doNotLink")
    f("cl", flow, "GateCheck", "ReturnDenied")

    write_sql = ("INSERT INTO agent_audit (agent_id, tool, target, decision, reason, detail) SELECT * FROM "
                 f"delegation_audit_row(CAST(?w_caller AS text), '{tool}', CAST(?w_req AS text));")
    app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", write_sql,
                [("w_caller", "=$flow.tokenInfo.sub"), ("w_req", "=$flow.arguments.request")])
    gate_sql = f"SELECT * FROM delegation_gate(CAST(?r_caller AS text), '{tool}');"
    app.bake_pg(flow, "GateCheck", "act_postgresql_query", gate_sql, [("r_caller", "=$flow.tokenInfo.sub")],
                result_columns(gate_sql))

    S = f"{flow}.{act}.settings"
    f("sa", "activity", f"{S}.llmProviderConnection", app.conn_ref("OpenAIConn"))
    f("sa", "activity", f"{S}.model", "LLM_Model", "-C", "app-property")
    f("sa", "activity", f"{S}.temperature", "0", "--type", "number")
    f("sa", "activity", f"{S}.tokenLimit", "8000", "--type", "number")
    f("sa", "activity", f"{S}.enableGuardrails", "true", "--type", "boolean")
    f("sa", "activity", f"{S}.redactSensitiveData", "false", "--type", "boolean")
    f("sa", "activity", f"{S}.responseType", "Text")
    f("sa", "activity", f"{S}.conversationStoreType", "None")          # stateless per delegation
    f("sa", "activity", f"{S}.systemPrompt", sp["prompt"])
    f("sa", "activity", f"{S}.mcpServers", "--jsonValue", json.dumps([app.conn_ref(sp["conn"])]))
    f("mm", f"{flow}.{act}.input.userPrompt", "=coerce.toString($flow.arguments.request)")
    f("mm", f"{flow}.ReturnOK.input.mappings.response.mapping.data", f"=$activity[{act}].response")
    f("mm", f"{flow}.ReturnDenied.input.mappings.response.mapping.data",
      '=string.concat("DELEGATION_REFUSED: ", $activity[GateCheck].Output.records[0].reason)')

    # branch on the registry decision (link condition values take no leading '=')
    links = next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)["data"]["links"]
    cond = {act: '$activity[GateCheck].Output.records[0].decision == "ALLOWED"',
            "ReturnDenied": '$activity[GateCheck].Output.records[0].decision != "ALLOWED"'}
    for i, ln in enumerate(links):
        if ln["from"] == "GateCheck" and ln["to"] in cond:
            f("sa", "flow", f"{flow}.links[{i}].type", "expression", "--force")
            f("sa", "flow", f"{flow}.links[{i}].value", cond[ln["to"]], "--force")

    f("cth", flow, TRIG, sp["desc"], "--mcpHandlerType", "Tool", "--mcpHandlerName", tool, "--mcpHandlerDescription", sp["desc"])
    f("wth", flow, f"{TRIG}.{flow}", "--force")
    f("wth", flow, f"{TRIG}.{flow}", "--force", "--input", "arguments:object,tokenInfo:object", "--inputs-only")
    props = {a: {"type": "string", "description": d} for a, d in HDR}
    f("cs", f"{tool}_Args", json.dumps({"type": "object", "properties": props, "required": [a for a, _ in HDR]}))
    f("sa", "handler", f"{TRIG}.{flow}.schemas.output.arguments", f"{tool}_Args", "-C", "schema", "--force")
    f("sa", "handler", f"{TRIG}.{flow}.schemas.reply.response", "ToolResponse", "-C", "schema", "--force")
    f("sa", "handler", f"{TRIG}.{flow}.settings.scope", sp["scope"])
    f("sa", "handler", f"{TRIG}.{flow}.settings.toolTitle", tool.replace("_", " ").title())
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", "false")
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", "false")
    f("sa", "handler", f"{TRIG}.{flow}.settings.idempotentToolHint", "--jsonValue", "false")
    f("sa", "handler", f"{TRIG}.{flow}.settings.openWorldToolHint", "--jsonValue", "false")
    compact = json.dumps({a: {"type": "string"} for a, _ in HDR})
    resp = '{"data":{"type":"string"},"error":{"type":"string"}}'
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile", jtmp([
        {"name": "arguments", "type": "object", "schema": {"type": "json", "value": compact}},
        {"name": "tokenInfo", "type": "object", "schema": {"type": "json", "value": json.dumps(TOKEN_INFO)}}]), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile",
      jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": resp}}]), "--force")
    fe_in = {"type": "object", "title": TRIG, "properties": {
        "arguments": {"type": "object", "properties": props, "required": [a for a, _ in HDR]},
        "tokenInfo": {"type": "object", "properties": TOKEN_INFO}}}
    fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": json.loads(resp)}},
              "required": ["response"]}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

# verify the AI Agents are bound to the LLM provider connection (see the note above)
for r in app.load()["resources"]:
    for t in r["data"]["tasks"]:
        if "agentactivity" in t["activity"]["ref"]:
            got = t["activity"]["settings"]["llmProviderConnection"]
            assert got == app.conn_ref("OpenAIConn"), f"{t['id']} llmProviderConnection={got}"
print("\nSpecialists build complete:", app.file)
