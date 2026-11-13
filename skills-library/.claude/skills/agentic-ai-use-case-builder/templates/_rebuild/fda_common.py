"""Shared helpers for the fda drivers (agentic-ai-use-case-builder skill).

Config is read at RUN time - nothing secret or machine-specific is stored in these scripts:
  env vars win (FDA, PSQL, PG_HOST, PG_PORT, PG_USER, PG_PWD/PG_PASSWORD, LLM_API_KEY, LLM_MODEL, LLM_BASE_URL),
  otherwise CONFIG_MD (default: the nearest skills-library/.claude/skills/config.md above this script).
The fda binary: env FDA (the CLI the agent resolved per AGENT.md) wins; otherwise the newest installed
Flogo VS Code extension, 2.x preferred, 3.x as fallback.

Flogo version (the drivers are version-neutral): env FLOGO_TYPE (or config.md FLOGO_TYPE) = 2x | 3x picks the
app format; unset -> the version of the resolved fda CLI. 2.x writes <App>.flogo (one JSON file); 3.x writes an
<App>/ project folder (app.fgmd, app.fgprops, flows/, connections/, triggers/, schemas/). Either CLI can create
either format (create-project gets -T 2x|3x). App.load() returns the same app model for both versions: the
.flogo JSON for 2.x, `fda da any --json` (the merged project view) for 3.x.
"""
import glob, json, os, re, shutil, subprocess, sys, tempfile, uuid

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

def _norm_key(k):
    """config.md keys match case-insensitively and a space equals an underscore: `API Key:` == `API_Key:`."""
    return re.sub(r"\s+", "_", k.strip()).upper()

class _Config(dict):
    def get(self, key, default=None): return dict.get(self, _norm_key(key), default)

def _config():
    cfg = _Config()
    if os.path.exists(CONFIG_MD):
        for line in open(CONFIG_MD, encoding="utf-8"):
            m = re.match(r"\|\s*([A-Za-z][A-Za-z0-9_ ]*?)\s*\|\s*`([^`]*)`", line)          # | KEY | `value` |
            if m: k, v = _norm_key(m.group(1)), m.group(2).strip()
            else:
                m = re.match(r"^\s*([A-Za-z][A-Za-z0-9_]*(?: [A-Za-z0-9_]+){0,2})\s*:\s*(.*?)\s*$", line)   # Key: value / Key Name: value
                if not m or _norm_key(m.group(1)) in cfg: continue
                k, v = _norm_key(m.group(1)), m.group(2)
            if re.fullmatch(r"<[^>]*>", v): continue                       # `<placeholder>` = unset
            cfg[k] = v
    return cfg

CFG = _config()
def setting(env, key, default=None):
    v = os.environ.get(env)
    if v is None: v = CFG.get(key, default)
    if v is None: sys.exit(f"missing setting {env} (env) / {key} (config.md)")
    return v

def _find_fda():
    """env FDA (the CLI resolved per AGENT.md - the skill exports it) > newest installed extension, 2.x preferred
    > config.md. The app format is FLOGO_TYPE, not the CLI's version (either CLI creates either format).
    Extension paths change on every update, so never pin one."""
    if os.environ.get("FDA"): return os.environ["FDA"]
    exe = "flogodesign-cli.exe" if os.name == "nt" else "flogodesign-cli"
    home = os.path.expanduser("~")
    for pat in ("tibco.flogo-2.*", "tibco.flogo3-*"):
        hits = [h for ext_dir in (".vscode", ".vscode-insiders", ".vscode-server")
                for h in glob.glob(os.path.join(home, ext_dir, "extensions", pat, "bin", exe))]
        if hits:
            best = max(hits, key=os.path.getmtime)
            print(f"fda: FDA not set - using {best} (export FDA=<path> to choose another)", file=sys.stderr)
            return best
    p = CFG.get("FLOGODESIGN_CLI_PATH", "").strip('"')       # config.example.md: full exe path; some configs: the bin dir
    if p: return p if p.lower().endswith((".exe", "flogodesign-cli")) else os.path.join(p, exe)
    sys.exit("flogodesign-cli not found: install the TIBCO Flogo VS Code extension or set FDA=<path>")

FDA = _find_fda()

def _flogo_type():
    """'2' or '3': env FLOGO_TYPE > config.md FLOGO_TYPE > the version of the resolved fda CLI."""
    v = (os.environ.get("FLOGO_TYPE") or CFG.get("FLOGO_TYPE") or "").strip().lower().rstrip("x").lstrip("v")
    if v in ("2", "3"): return v
    if v: sys.exit(f"FLOGO_TYPE={v!r}: use 2x or 3x")
    v = "3" if re.search(r"tibco\.flogo3-", FDA.replace("\\", "/")) else "2"
    print(f"fda: FLOGO_TYPE not set - building Flogo {v}.x apps (the CLI's own version; set FLOGO_TYPE=2x|3x)",
          file=sys.stderr)
    return v

FLOGO_TYPE = _flogo_type()
IS_3X = FLOGO_TYPE == "3"
PSQL = os.environ.get("PSQL") or CFG.get("PSQL_PATH") or shutil.which("psql") or "psql"   # env > config.md > PATH
PG = dict(host=setting("PG_HOST", "PG_HOST", "localhost"), port=setting("PG_PORT", "PG_PORT", "5432"),
          db=os.environ.get("PG_DB") or sys.exit("set PG_DB to the use case's database name"), user=setting("PG_USER", "PG_USER", "postgres"))
LLM = dict(provider=os.environ.get("LLM_PROVIDER", CFG.get("LLM_Provider") or "OpenAI"),
           model=setting("LLM_MODEL", "LLM_Model"),
           base_url=os.environ.get("LLM_BASE_URL", CFG.get("LLM_Base_URL", "")).strip())

def pg_password(): return os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or setting("PG_PWD", "PG_PASSWORD")
def llm_key():     return setting("LLM_API_KEY", "API_Key")

_ANSI = re.compile(r"\x1b\[[0-9;]*m")

class App:
    """One Flogo app, 2.x or 3.x (FLOGO_TYPE). `name` is the app name; a trailing .flogo is accepted and
    ignored, so App("XMCPServer") and App("XMCPServer.flogo") are the same app."""
    def __init__(self, name, out_dir=None):
        self.name = re.sub(r"\.flogo$", "", os.path.basename(name))
        base = os.path.join(out_dir or USE_CASE_DIR, self.name)
        self.file = base if IS_3X else base + ".flogo"       # 3.x: the project folder (holds app.fgmd)
        if os.path.exists(self.file):
            sys.exit(f"REFUSING: {self.file} exists. Replay into an empty folder (OUT_DIR=...). "
                     "Never regenerate an app that was opened in the designer - patch it surgically.")

    def fda(self, *args, allow_fail=False):
        args = [str(a) for a in args]
        target = self.file
        creating = bool(args) and args[0] in ("cp", "create-project")
        if creating:
            if not {"-T", "--flogo-type"} & set(args):
                args += ["-T", FLOGO_TYPE + "x"]           # the format is FLOGO_TYPE, whichever CLI runs it
            # The -f path's SHAPE decides the format: <dir>/<App>/app.fgmd -> 3.x project folder. A bare
            # <dir>/<App> (even with -T 3x) silently creates a single-file 2.x-style app named <App>.
            if IS_3X: target = os.path.join(self.file, "app.fgmd")
        r = subprocess.run([FDA, *args, "-f", target], capture_output=True, text=True, encoding="utf-8",
                           errors="replace")
        out = (r.stdout or "") + (r.stderr or "")
        if "(ERROR)" in out and not allow_fail:
            print("FAILED:", " ".join(args)[:300]); print(out[-1500:]); sys.exit(1)
        if creating and IS_3X and not os.path.isfile(os.path.join(self.file, "app.fgmd")):
            sys.exit(f"FAILED: create-project did not produce a Flogo 3.x project folder at {self.file}")
        print("  ok:", " ".join(args[:3])[:110])
        return out

    def load(self):
        """The app model: the .flogo JSON (2.x) or fda's merged project view (3.x) - same top-level shape."""
        if not IS_3X: return json.load(open(self.file, encoding="utf-8"))
        r = subprocess.run([FDA, "da", "any", "--json", "-f", self.file], capture_output=True, text=True,
                           encoding="utf-8", errors="replace")
        try: return json.loads(_ANSI.sub("", r.stdout))["flogoAttributes"]
        except (ValueError, KeyError): sys.exit(f"FAILED: fda da any --json on {self.file}:\n{(r.stdout + r.stderr)[-1500:]}")

    def conn_ids(self):
        c = self.load()["connections"]
        return {x["name"]: x["id"] for x in (c.values() if isinstance(c, dict) else c)}

    def conn_ref(self, name):
        """The value to WRITE into a Connection field: conn://<uuid> (2.x) or conn://<Name>.fgconn (3.x)."""
        if name not in self.conn_ids(): sys.exit(f"FAILED: no connection named {name!r} in {self.file}")
        return f"conn://{name}.fgconn" if IS_3X else "conn://" + self.conn_ids()[name]

    def is_conn(self, value, name):
        """Does a Connection value read back from load() bind connection `name`? 3.x's merged view shows
        conn://<Name> or conn://<Name>.fgconn depending on how the field was set, so accept both."""
        if IS_3X: return value in (f"conn://{name}", f"conn://{name}.fgconn")
        return value == self.conn_ref(name)

    def assert_conn(self, flow, task, name):
        d = self.load()
        t = next(t for r in d["resources"] if r["id"] == "flow:" + flow for t in r["data"]["tasks"] if t["id"] == task)
        got = (t["activity"].get("input") or {}).get("Connection")
        if not self.is_conn(got, name):
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
