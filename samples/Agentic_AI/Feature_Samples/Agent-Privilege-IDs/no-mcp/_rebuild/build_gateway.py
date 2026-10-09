#!/usr/bin/env python3
"""Build BankAPIGateway.flogo with fda only - a Flogo stand-in for the bank's identity provider + API gateway.

REST trigger on :9895
  POST /oauth/token   OAuth 2.0 client credentials. SQL token_request() checks the client (Basic header or form
                      fields, SHA-256 hashed secret) and computes the claims; the JWT activity signs them (HS256).
  /api/...            JWT activity verifies the bearer token (signature + exp) -> SQL api_gate() checks issuer,
                      audience and the endpoint's scope (401 / 403, refusals audited) -> on 200 the SAME guarded tool
                      SQL as the base sample runs with the agent ID from the token (registry = kill switch, audit).
Every schema (headers, body, path params) is INLINE - see the README note on schema references.

Re-run:  python no-mcp/_rebuild/build_gateway.py   (OUT_DIR=<empty dir> to replay)
Needs: bankops_agents loaded (for result columns); env GATEWAY_SIGNING_KEY (HS256 key), PG_PWD."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
NOMCP_DIR = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(os.path.dirname(NOMCP_DIR), "_rebuild"))
from fda_common import App, jtmp, result_columns  # noqa: E402
from tool_spec import TOOLS  # noqa: E402

KEY = os.environ.get("GATEWAY_SIGNING_KEY") or sys.exit("set GATEWAY_SIGNING_KEY (e.g. gw.<random>)")
T = {t["tool"]: t for t in TOOLS}
TRIG = "BankAPI"
HTTP = {   # tool -> (method, path, body args); path params are the {placeholders}
    "whoami":                   ("GET",  "/api/whoami", []),
    "get_account_summary":      ("GET",  "/api/accounts/{account_id}", []),
    "list_recent_transactions": ("GET",  "/api/accounts/{account_id}/transactions", []),
    "block_card":               ("POST", "/api/cards/{card_id}/block", ["reason"]),
    "request_limit_increase":   ("POST", "/api/accounts/{account_id}/limit-requests", ["new_daily_limit", "justification"]),
    "get_request_status":       ("GET",  "/api/limit-requests/{request_id}", []),
}
JWT_IN = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "properties": {
    "token": {"type": "string"}, "secret": {"type": "string"}, "algorithm": {"type": "string"},
    "header": {"type": "string"}, "payload": {"type": "string"}}}
JWT_CLAIMS = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "properties": {
    "iss": {"type": "string"}, "sub": {"type": "string"}, "aud": {"type": "array", "items": {"type": "string"}},
    "scp": {"type": "array", "items": {"type": "string"}}, "iat": {"type": "number"}, "exp": {"type": "number"}}}
DATA = {"records": {"type": "array", "items": {"type": "object", "properties": {}}}, "error": {"type": "string"},
        "required_scope": {"type": "string"}, "access_token": {"type": "string"}, "token_type": {"type": "string"},
        "expires_in": {"type": "number"}, "scope": {"type": "string"}}
HDR_NAMES = ["Authorization", "Content-Type", "Accept"]

app = App("BankAPIGateway.flogo", os.environ.get("OUT_DIR") or NOMCP_DIR)
f = app.fda


def inline(obj):
    v = json.dumps(obj)
    return json.dumps({"type": "json", "value": v, "fe_metadata": v})


def jwt_schemas(flow, act, sign):
    out = {"signedToken": {"type": "string"}} if sign else {"valid": {"type": "boolean"}}
    s = {"input": {"input": {"type": "json", "value": json.dumps(JWT_IN), "fe_metadata": json.dumps(JWT_IN)}}}
    if not sign:
        s["output"] = {"claims": {"type": "json", "value": json.dumps(JWT_CLAIMS), "fe_metadata": json.dumps(JWT_CLAIMS)}}
    f("sa", "activity", f"{flow}.{act}.schemas", "--jsonFile", jtmp(s), "--force")


def branch(flow, gate_act, ok_to, deny_to):
    links = next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)["data"]["links"]
    cond = {ok_to: f"$activity[{gate_act}].Output.records[0].status == 200",
            deny_to: f"$activity[{gate_act}].Output.records[0].status != 200"}
    for i, ln in enumerate(links):
        if ln["from"] == gate_act and ln["to"] in cond:
            f("sa", "flow", f"{flow}.links[{i}].type", "expression", "--force")
            f("sa", "flow", f"{flow}.links[{i}].value", cond[ln["to"]], "--force")


def handler(flow, method, path, path_args, body_args):
    f("cth", flow, TRIG, f"{method} {path}", "--restResourcePath", path, "--restHandlerMethod", method)
    ins = "headers:object,body:object,requestURI:string,method:string" + (",pathParams:object" if path_args else "")
    f("wth", flow, f"{TRIG}.{flow}", "--force", "--input", ins, "--output", "code:integer,data:object")
    hprops = {k: {"type": "string"} for k in HDR_NAMES}
    hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false"} for k in HDR_NAMES]
    f("sa", "handler", f"{TRIG}.{flow}.schemas.output.headers", "--jsonValue", json.dumps(
        {"type": "json", "value": json.dumps({"type": "object", "properties": hprops}), "fe_metadata": json.dumps(hfe)}),
      "--force")
    if path_args:
        pp = {k: {"type": "string"} for k in path_args}
        f("sa", "handler", f"{TRIG}.{flow}.schemas.output.pathParams", "--jsonValue", json.dumps(
            {"type": "json", "value": json.dumps({"type": "object", "properties": pp}),
             "fe_metadata": json.dumps([{"parameterName": k, "type": "string"} for k in path_args])}), "--force")
    if body_args:
        f("sa", "handler", f"{TRIG}.{flow}.schemas.output.body", "--jsonValue",
          inline({"type": "object", "properties": {k: {"type": "string"} for k in body_args}}), "--force")
    meta_in = [{"name": "headers", "type": "object", "schema": {"type": "json", "value": json.dumps(hprops)}},
               {"name": "body", "type": "object", "schema": {"type": "json", "value": json.dumps(
                   {k: {"type": "string"} for k in body_args})}},
               {"name": "requestURI", "type": "string"}, {"name": "method", "type": "string"}]
    if path_args:
        meta_in.append({"name": "pathParams", "type": "object",
                        "schema": {"type": "json", "value": json.dumps({k: {"type": "string"} for k in path_args})}})
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile", jtmp(meta_in), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile", jtmp(
        [{"name": "code", "type": "integer"}, {"name": "data", "type": "object",
                                               "schema": {"type": "json", "value": json.dumps(DATA)}}]), "--force")
    fe_props = {"headers": {"type": "object", "properties": hprops},
                "body": {"type": "object", "properties": {k: {"type": "string"} for k in body_args}},
                "requestURI": {"type": "string"}, "method": {"type": "string"}}
    if path_args:
        fe_props["pathParams"] = {"type": "object", "properties": {k: {"type": "string"} for k in path_args}}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps({"type": "object", "title": TRIG, "properties": fe_props}),
      "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(
        {"type": "object", "title": "Inputs", "properties": {"code": {"type": "integer"},
                                                             "data": {"type": "object", "properties": DATA}}}), "--force")


print("== project, PostgreSQL, properties ==")
f("cp", "BankAPIGateway", "Stand-in for the bank's identity provider + API gateway (OAuth2 client credentials, JWT, scopes, audit)")
app.postgres_connection()
f("cap", "Gateway.Port", "number", "9895")
f("cap", "Gateway.Signing_Key", "string", KEY)
f("cap", "Gateway.Token_TTL_Seconds", "string", "600")
f("ct", TRIG, "tr_rest", "Bank identity provider + API gateway")
f("sa", "trigger", f"{TRIG}.settings.port", "Gateway.Port", "-C", "app-property")

print("== POST /oauth/token ==")
FL = "oauth_token_flow"
f("cf", FL, "OAuth 2.0 client-credentials token endpoint")
f("ca", FL, "TokenCheck", "act_postgresql_query", "Check the client, compute claims", "-C", "PostgresConn")
f("ca", FL, "SignToken", "act_general_jwt", "Sign the access token")
f("ca", FL, "ReturnToken", "act_default_actreturn", "200 + token")
f("ca", FL, "ReturnTokenError", "act_default_actreturn", "OAuth error", "--doNotLink")
f("cl", FL, "TokenCheck", "ReturnTokenError")
tsql = ("SELECT t.*, '{\"alg\":\"HS256\",\"typ\":\"JWT\"}' AS jwt_header FROM token_request(CAST(?r_auth AS text), "
        "CAST(?r_grant AS text), CAST(?r_cid AS text), CAST(?r_sec AS text), CAST(?r_scope AS text), "
        "CAST(?r_ttl AS text)) t;")
app.bake_pg(FL, "TokenCheck", "act_postgresql_query", tsql, [
    ("r_auth", "=coerce.toString($flow.headers.Authorization)"), ("r_grant", "=coerce.toString($flow.body.grant_type)"),
    ("r_cid", "=coerce.toString($flow.body.client_id)"), ("r_sec", "=coerce.toString($flow.body.client_secret)"),
    ("r_scope", "=coerce.toString($flow.body.scope)"), ("r_ttl", '=$property["Gateway.Token_TTL_Seconds"]')],
    result_columns(tsql))
f("sa", "activity", f"{FL}.SignToken.settings.mode", "Sign")
jwt_schemas(FL, "SignToken", sign=True)
rec = "$activity[TokenCheck].Output.records[0]"
for k, v in {"header": f"={rec}.jwt_header", "payload": f"={rec}.claims",
             "secret": '=$property["Gateway.Signing_Key"]', "algorithm": '="HS256"'}.items():
    f("mm", f"{FL}.SignToken.input.input.mapping.{k}", v)
f("mm", f"{FL}.ReturnToken.input.mappings.code", "=200")
for k, v in {"access_token": "=$activity[SignToken].signedToken", "token_type": '="Bearer"',
             "expires_in": f"={rec}.expires_in", "scope": f"={rec}.scope"}.items():
    f("mm", f"{FL}.ReturnToken.input.mappings.data.mapping.{k}", v)
f("mm", f"{FL}.ReturnTokenError.input.mappings.code", f"={rec}.status")
f("mm", f"{FL}.ReturnTokenError.input.mappings.data.mapping.error", f"={rec}.error")
branch(FL, "TokenCheck", "SignToken", "ReturnTokenError")
handler(FL, "POST", "/oauth/token", [], ["grant_type", "scope", "client_id", "client_secret"])

for tool, (method, path, body_args) in HTTP.items():
    t = T[tool]
    FL = f"api_{tool}_flow"
    path_args = [seg[1:-1] for seg in path.split("/") if seg.startswith("{")]
    scope = t["scope"]
    print(f"== {method} {path}  (scope: {scope or 'any valid token'}) ==")
    f("cf", FL, f"{method} {path} -> {tool}")
    f("ca", FL, "VerifyToken", "act_general_jwt", "Verify the bearer token")
    f("ca", FL, "AuditDenial", "act_postgresql_insert", "Audit a missing-scope refusal", "-C", "PostgresConn")
    f("ca", FL, "Gate", "act_postgresql_query", "Issuer, audience, scope", "-C", "PostgresConn")
    f("ca", FL, "ToolWrite", "act_postgresql_insert", "Audit + guarded write", "-C", "PostgresConn")
    f("ca", FL, "ToolRead", "act_postgresql_query", "Outcome", "-C", "PostgresConn")
    f("ca", FL, "ReturnOK", "act_default_actreturn", "200 + records")
    f("ca", FL, "ReturnDenied", "act_default_actreturn", "401 / 403", "--doNotLink")
    f("cl", FL, "Gate", "ReturnDenied")

    jwt_schemas(FL, "VerifyToken", sign=False)
    for k, v in {"token": '=string.replaceAll(coerce.toString($flow.headers.Authorization), "Bearer ", "")',
                 "secret": '=$property["Gateway.Signing_Key"]', "algorithm": '="HS256"'}.items():
        f("mm", f"{FL}.VerifyToken.input.input.mapping.{k}", v)
    valid, claims = "=coerce.toString($activity[VerifyToken].valid)", "=coerce.toString($activity[VerifyToken].claims)"
    def arg(name):
        return f"=coerce.toString($flow.pathParams.{name})" if name in path_args else f"=coerce.toString($flow.body.{name})"
    target = arg(t["args"][0][0]) if t["args"] else '=""'
    app.bake_pg(FL, "AuditDenial", "act_postgresql_insert",
                "INSERT INTO agent_audit (agent_id, tool, target, decision, reason, detail) SELECT * FROM "
                f"api_denial_row(CAST(?w_valid AS text), CAST(?w_claims AS text), '{scope}', '{tool}', CAST(?w_target AS text));",
                [("w_valid", valid), ("w_claims", claims), ("w_target", target)])
    gsql = f"SELECT * FROM api_gate(CAST(?r_valid AS text), CAST(?r_claims AS text), '{scope}');"
    app.bake_pg(FL, "Gate", "act_postgresql_query", gsql, [("r_valid", valid), ("r_claims", claims)], result_columns(gsql))
    src = {"sub": "=$activity[Gate].Output.records[0].agent_id",
           "scopes": "=coerce.toString($activity[VerifyToken].claims.scp)"}
    sql, params = t["write"]
    app.bake_pg(FL, "ToolWrite", "act_postgresql_insert", sql, [(p, src.get(s) or arg(s)) for p, s in params])
    sql, params = t["read"]
    app.bake_pg(FL, "ToolRead", "act_postgresql_query", sql, [(p, src.get(s) or arg(s)) for p, s in params],
                result_columns(sql))
    f("mm", f"{FL}.ReturnOK.input.mappings.code", "=200")
    f("mm", f"{FL}.ReturnOK.input.mappings.data.mapping.records", "=$activity[ToolRead].Output.records")
    f("mm", f"{FL}.ReturnDenied.input.mappings.code", "=$activity[Gate].Output.records[0].status")
    f("mm", f"{FL}.ReturnDenied.input.mappings.data.mapping.error", "=$activity[Gate].Output.records[0].error")
    f("mm", f"{FL}.ReturnDenied.input.mappings.data.mapping.required_scope",
      "=$activity[Gate].Output.records[0].required_scope")
    branch(FL, "Gate", "ToolWrite", "ReturnDenied")
    handler(FL, method, path, path_args, body_args)

print("\nGateway build complete:", app.file)
