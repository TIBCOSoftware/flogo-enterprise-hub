#!/usr/bin/env python3
"""Build AuthorServicesAgents.flogo with fda only: ONE A2A agent (journal_match_agent).
It is an agent because matching a manuscript to a journal's aims & scope is semantic reasoning.
It gets topic keywords only - never the author's identity - and cannot write anything.
Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp, result_columns
from tool_spec import SEARCH_JOURNALS as T

app = App("AuthorServicesAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
NAME, PORT = "journal_match_agent", "9843"
FLOW = f"{NAME}_flow"

ADESC = ("Recommends alternative journals for a manuscript from its title, abstract, keywords and word count. "
         "Read-only: it searches the journal catalogue and ranks candidates; it cannot transfer anything.")
SYS = """You recommend journals for a manuscript that received a transfer offer. You are given the manuscript's
title, abstract, keywords, article type, word count and current journal code. You are never given the author's identity.

1. Extract 4-8 topic keywords and one broad subject area, then call the search_journals tool exactly once.
   If it returns nothing useful, retry once with broader keywords.
2. From the returned journals only, pick up to 3 that best fit the manuscript's topic and method.
   Exclude the current journal. Exclude any journal whose word_limit is below the manuscript's word count
   and say which ones you excluded for that reason.
3. For each pick return: journal_code, title, one sentence on why the aims & scope fit, oa_model, apc_usd,
   word_limit and median_days_to_first_decision, copied exactly from the tool result.

Never invent journals, codes, fees or turnaround times. Do not state whether the author's institution covers
the fee - that is checked elsewhere. Reply as a short numbered list."""

print("== project + connections ==")
f("cp", "AuthorServicesAgents", "Author Services A2A agent - journal matching (read-only)")
app.llm_connection()
app.postgres_connection()
f("cap", f"{NAME}_PORT", "string", PORT)
f("cap", f"{NAME}_URL", "string", f"http://localhost:{PORT}")

print(f"== agent {NAME} ==")
f("ct", NAME, "tr_agent", ADESC)
f("sa", "trigger", f"{NAME}.settings.llmProviderConnection", "OpenAIConn", "-C", "connection")
f("sa", "trigger", f"{NAME}.settings.agentName", NAME)
f("sa", "trigger", f"{NAME}.settings.agentDescription", ADESC)
f("sa", "trigger", f"{NAME}.settings.agentType", "A2A Server")
f("sa", "trigger", f"{NAME}.settings.agentPort", f"{NAME}_PORT", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.agentUrl", f"{NAME}_URL", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.model", "LLM_Model", "-C", "app-property")
f("sa", "trigger", f"{NAME}.settings.temperature", "0", "--type", "number")      # 0 = omitted (provider default)
f("sa", "trigger", f"{NAME}.settings.enableGuardrails", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.redactSensitiveData", "true", "--type", "boolean")
f("sa", "trigger", f"{NAME}.settings.conversationStoreType", "Memory")
f("sa", "trigger", f"{NAME}.settings.memoryMaxSize", "20", "--type", "number")
f("sa", "trigger", f"{NAME}.settings.systemPrompt", SYS)

print("== tool flow search_journals ==")
f("cf", FLOW, T["desc"])
f("ca", FLOW, "SearchJournals", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
f("ca", FLOW, "Return", "act_default_actreturn", "Simple Return")
sql, params = T["read"]
app.bake_pg(FLOW, "SearchJournals", "act_postgresql_query", sql,
            [(p, f"=$flow.toolParams.{a}") for p, a in params], result_columns(sql))
f("mm", f"{FLOW}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[SearchJournals].Output)")

f("cth", FLOW, NAME, T["desc"])
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolName", "search_journals")
f("sa", "handler", f"{NAME}.{FLOW}.settings.agentToolDescription", T["desc"])
f("wth", FLOW, f"{NAME}.{FLOW}", "--force", "--input", "toolParams:object", "--output", "response:object")
props = {a: {"type": "string", "description": d} for a, d in T["args"]}
# INLINE schemas: the AI Agent Trigger reads toolParams only inline - a schema:// reference gives the LLM a
# tool with NO parameters (FGAI-155). The MCP Server trigger resolves references; this trigger does not.
_tp = json.dumps({"type": "object", "properties": props, "required": ["keywords"]})
f("sa", "handler", f"{NAME}.{FLOW}.schemas.output.toolParams", "--jsonValue",
  json.dumps({"type": "json", "value": _tp, "fe_metadata": _tp}), "--force")
_rs = '{"type":"object","properties":{"data":{"type":"string"}}}'
f("sa", "handler", f"{NAME}.{FLOW}.schemas.reply.response", "--jsonValue",
  json.dumps({"type": "json", "value": _rs, "fe_metadata": _rs}), "--force")

compact = json.dumps({a: {"type": "string"} for a, _ in T["args"]})
f("sa", "flow", f"{FLOW}.metadata.input", "--jsonFile",
  jtmp([{"name": "toolParams", "type": "object", "schema": {"type": "json", "value": compact}}]), "--force")
f("sa", "flow", f"{FLOW}.metadata.output", "--jsonFile",
  jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": '{"data":{"type":"string"}}'}}]), "--force")
fe_in = {"type": "object", "title": NAME, "properties": {"toolParams": {"type": "object", "properties": props, "required": ["keywords"]}}}
fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": {"data": {"type": "string"}}}}, "required": []}
f("sa", "flow", f"{FLOW}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
f("sa", "flow", f"{FLOW}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

print("\nA2A build complete:", app.file)
