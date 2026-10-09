"""Shared helpers for the fda drivers (agentic-ai-use-case-builder skill).

Config is read at RUN time - nothing secret or machine-specific is stored in these scripts:
  env vars win (FDA, PSQL, PG_HOST, PG_PORT, PG_USER, PG_PWD, LLM_API_KEY, LLM_MODEL, LLM_BASE_URL),
  otherwise CONFIG_MD (default: the nearest skills-library/.claude/skills/config.md above this script).
The fda binary is discovered like AGENT.md does it: newest tibco.flogo-* VS Code extension.
"""
import glob, json, os, re, subprocess, sys, tempfile, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
USE_CASE_DIR = os.path.dirname(HERE)

def _find_config_md():
    """Walk up from this script to the first skills-library/.claude/skills/config.md (or .claude/skills/config.md)."""
    d = HERE
    while True:
        for rel in (("skills-library", ".claude", "skills", "config.md"), (".claude", "skills", "config.md")):
            p = os.path.join(d, *rel)
            if os.path.exists(p): return p
        parent = os.path.dirname(d)
        if parent == d: return ""
        d = parent

CONFIG_MD = os.environ.get("CONFIG_MD") or _find_config_md()

def _config():
    cfg = {}
    if os.path.exists(CONFIG_MD):
        for line in open(CONFIG_MD, encoding="utf-8"):
            m = re.match(r"\|\s*([A-Za-z][A-Za-z0-9_]*)\s*\|\s*`([^`]*)`", line)          # | KEY | `value` |
            if m: cfg[m.group(1)] = m.group(2).strip(); continue
            m = re.match(r"^\s*([A-Za-z_]+)\s*:\s*(.*?)\s*$", line)          # Key: value
            if m and m.group(1) not in cfg: cfg[m.group(1)] = m.group(2)
    return cfg

CFG = _config()
def setting(env, key, default=None):
    v = os.environ.get(env)
    if v is None: v = CFG.get(key, default)
    if v is None: sys.exit(f"missing setting {env} (env) / {key} (config.md)")
    return v

def _find_fda():
    """env FDA > newest tibco.flogo-* extension (path changes on every update, so never pin it) > config.md."""
    if os.environ.get("FDA"): return os.environ["FDA"]
    exe = "flogodesign-cli.exe" if os.name == "nt" else "flogodesign-cli"
    home = os.path.expanduser("~")
    for ext_dir in (".vscode", ".vscode-insiders", ".vscode-server"):
        hits = glob.glob(os.path.join(home, ext_dir, "extensions", "tibco.flogo-*", "bin", exe))
        if hits: return max(hits, key=os.path.getmtime)
    p = CFG.get("FLOGODESIGN_CLI_PATH", "").strip('"')       # config.example.md: full exe path; some configs: the bin dir
    if p: return p if p.lower().endswith((".exe", "flogodesign-cli")) else os.path.join(p, exe)
    sys.exit("flogodesign-cli not found: install the TIBCO Flogo VS Code extension or set FDA=<path>")

FDA = _find_fda()
PSQL = setting("PSQL", "PSQL_PATH", "psql")
PG = dict(host=setting("PG_HOST", "PG_HOST", "localhost"), port=setting("PG_PORT", "PG_PORT", "5432"),
          db=os.environ.get("PG_DB", "payments_governed"), user=setting("PG_USER", "PG_USER", "postgres"))
LLM = dict(provider=os.environ.get("LLM_PROVIDER", CFG.get("LLM_Provider") or "OpenAI"),
           model=setting("LLM_MODEL", "LLM_Model"),
           base_url=os.environ.get("LLM_BASE_URL", CFG.get("LLM_Base_URL", "")).strip())

def pg_password(): return setting("PG_PWD", "PG_PASSWORD")
def llm_key():     return setting("LLM_API_KEY", "API_Key")

class App:
    def __init__(self, filename, out_dir=None):
        self.file = os.path.join(out_dir or USE_CASE_DIR, filename)
        if os.path.exists(self.file):
            sys.exit(f"REFUSING: {self.file} exists. Replay into an empty folder (OUT_DIR=...). "
                     "Never regenerate an app that was opened in the designer - patch it surgically.")

    def fda(self, *args, allow_fail=False):
        r = subprocess.run([FDA, *map(str, args), "-f", self.file], capture_output=True, text=True)
        out = (r.stdout or "") + (r.stderr or "")
        if "(ERROR)" in out and not allow_fail:
            print("FAILED:", " ".join(map(str, args))[:300]); print(out[-1500:]); sys.exit(1)
        print("  ok:", " ".join(str(a) for a in args[:3])[:110])
        return out

    def load(self): return json.load(open(self.file, encoding="utf-8"))

    def conn_ids(self):
        c = self.load()["connections"]
        return {x["name"]: x["id"] for x in (c.values() if isinstance(c, dict) else c)}

    def conn_ref(self, name): return "conn://" + self.conn_ids()[name]

    def assert_conn(self, flow, task, name):
        d = self.load()
        t = next(t for r in d["resources"] if r["id"] == "flow:" + flow for t in r["data"]["tasks"] if t["id"] == task)
        got = (t["activity"].get("input") or {}).get("Connection")
        if got != self.conn_ref(name):
            sys.exit(f"FAILED: {flow}.{task} Connection={got!r}, expected {name}")

    def cap_empty(self, name):
        self.fda("cap", name, "string", "placeholder")          # `cap ""` writes the literal New_value
        idx = [p["name"] for p in self.load()["properties"]].index(name)
        self.fda("sa", "any", f"properties.{idx}.value", "--jsonValue", '""')

    def postgres_connection(self):
        f = self.fda
        f("cap", "PostgreSQL.PostgresConn.Host", "string", PG["host"])
        f("cap", "PostgreSQL.PostgresConn.Port", "number", PG["port"])
        f("cap", "PostgreSQL.PostgresConn.Database_Name", "string", PG["db"])
        f("cap", "PostgreSQL.PostgresConn.User", "string", PG["user"])
        f("cap", "PostgreSQL.PostgresConn.Password", "string", pg_password())
        f("cc", "PostgresConn", "con_postgresql")
        f("sa", "connection", "PostgresConn.settings.databaseType", "PostgreSQL")
        for k, p in [("host", "Host"), ("port", "Port"), ("databaseName", "Database_Name"), ("user", "User"), ("password", "Password")]:
            f("sa", "connection", f"PostgresConn.settings.{k}", f"PostgreSQL.PostgresConn.{p}", "-C", "app-property")

    def llm_connection(self):
        f = self.fda
        f("cap", "AgenticAI.OpenAIConn.LLM_Provider", "string", LLM["provider"])
        f("cap", "AgenticAI.OpenAIConn.API_Key", "string", llm_key())
        if LLM["base_url"]: f("cap", "AgenticAI.OpenAIConn.LLM_Base_URL", "string", LLM["base_url"])
        else:               self.cap_empty("AgenticAI.OpenAIConn.LLM_Base_URL")
        f("cap", "LLM_Model", "string", LLM["model"])
        f("cc", "OpenAIConn", "con_llmprovider")
        f("sa", "connection", "OpenAIConn.settings.llmProvider", "AgenticAI.OpenAIConn.LLM_Provider", "-C", "app-property")
        f("sa", "connection", "OpenAIConn.settings.apiKey", "AgenticAI.OpenAIConn.API_Key", "-C", "app-property")
        f("sa", "connection", "OpenAIConn.settings.llmProviderUrl", "AgenticAI.OpenAIConn.LLM_Base_URL", "-C", "app-property")

    def bake_pg(self, flow, act, ref, query, params, result_cols=()):
        """Full 3-part PostgreSQL contract in parameters mode. params: [(placeholder, mapper expr)]."""
        is_insert = ref == "act_postgresql_insert"
        fields = [{"FieldName": p, "Type": "LONGVARCHAR", "Selected": False, "Parameter": True,
                   "isEditable": False, "Value": False} for p, _ in params]
        fields += [{"FieldName": n, "Type": t, "Selected": True, "Parameter": False, "isEditable": False}
                   for n, t in result_cols]
        inp = {"Connection": self.conn_ref("PostgresConn"), "QueryName": "", "Schema": "public", "Query": query,
               "manualmode": False, "Fields": fields, "RuntimeQuery": "", "State": str(uuid.uuid4()) + query,
               "input": {"mapping": {"parameters": {p: e for p, e in params}}}}
        if not is_insert: inp["fetchMetadata"] = False
        self.fda("sa", "activity", f"{flow}.{act}.input", "--jsonFile", jtmp(inp), "--force")
        d = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "definitions": {}, "properties": {}}
        if is_insert: d["properties"]["values"] = {"type": "array", "items": {"type": "object", "properties": {}}}
        d["properties"]["parameters"] = {"type": "object", "properties": {p: {"type": "string"} for p, _ in params}}
        rec = {n: {"type": "number" if t in ("INTEGER", "NUMERIC", "REAL") else "string"} for n, t in result_cols}
        out = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "definitions": {},
               "properties": {"records": {"type": "array", "items": {"type": "object", "properties": rec}}}}
        iv, ov = json.dumps(d), json.dumps(out)
        self.fda("sa", "activity", f"{flow}.{act}.schemas", "--jsonFile",
                 jtmp({"input": {"input": {"type": "json", "value": iv, "fe_metadata": iv}},
                       "output": {"Output": {"type": "json", "value": ov, "fe_metadata": ov}}}), "--force")
        self.assert_conn(flow, act, "PostgresConn")

def jtmp(obj):
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(obj, f); f.close(); return f.name

_TYPES = {"character varying": "VARCHAR", "text": "LONGVARCHAR", "integer": "INTEGER", "numeric": "NUMERIC",
          "timestamp without time zone": "TIMESTAMP", "date": "DATE", "real": "REAL", "boolean": "BOOLEAN"}

def result_columns(select_sql):
    """Column names/types of a SELECT via psql \\gdesc (placeholders replaced by NULL)."""
    sql = re.sub(r"\?\w+", "NULL", select_sql).rstrip(";") + " \\gdesc\n"
    env = dict(os.environ, PGPASSWORD=pg_password())
    r = subprocess.run([PSQL, "-h", PG["host"], "-p", PG["port"], "-U", PG["user"], "-d", PG["db"], "-At", "-F", "|"],
                       input=sql, capture_output=True, text=True, env=env)
    if r.returncode or not r.stdout.strip(): sys.exit(f"psql \\gdesc failed: {r.stderr}")
    return [(n, _TYPES.get(t.split("(")[0], "VARCHAR")) for n, t in (l.split("|", 1) for l in r.stdout.strip().splitlines())]
