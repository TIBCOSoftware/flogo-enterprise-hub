#!/usr/bin/env python3
"""One-command setup for the governed Industry Use-Case agentic samples.

Gets a sample ready to run on a fresh machine. v1 steps, in order:

    check    -> prerequisites (delegates to the repo preflight)
    config   -> config.md exists and the required keys are filled
    validate -> the PostgreSQL connection works AND the LLM key/model is reachable
    context  -> a flogobuild build context exists (creates one if needed; -u extensions for RAG)
    db       -> create the sample database and load database.sql
    build    -> build runnable executables into <sample>/bin (your creds injected into the copies only)

It does NOT start the apps. Start / stop / test them yourself afterwards -- see RUNNING_THE_SAMPLES.md
(MCP Server -> Agents -> Orchestrator, then connect the Chatbot).

Usage:
    python setup.py --list
    python setup.py <Sample_Use_Case folder name or path>
    python setup.py <sample> --steps check,config,validate,context,db,build   # subset; default = all
    python setup.py <sample> --force-db          # drop & recreate the sample database
    python setup.py <sample> --context <name>    # force a specific flogobuild context

Stdlib only; Windows / macOS / Linux. Reads skills-library/.claude/skills/config.md. Never prints secrets.
The committed .flogo files are never modified: creds are injected only into the ./bin build copies
(./bin is git-ignored).
"""
import argparse, glob, json, os, re, shutil, subprocess, sys, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))          # .../samples/Agentic_AI/Industry_Use_Cases
ALL_STEPS = ["check", "config", "validate", "context", "db", "build"]
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def say(msg=""):
    print(msg, flush=True)


def hdr(title):
    print("\n==== %s ====" % title, flush=True)


# ----------------------------------------------------------------- repo layout + config.md
def _repo_root():
    d = HERE
    while True:
        if os.path.isdir(os.path.join(d, "skills-library")) and os.path.isdir(os.path.join(d, ".git")):
            return d
        p = os.path.dirname(d)
        if p == d:
            return os.path.abspath(os.path.join(HERE, "..", "..", ".."))   # fallback by known depth
        d = p


ROOT = _repo_root()
PREFLIGHT = os.path.join(ROOT, "skills-library", ".claude", "skills",
                         "agentic-ai-use-case-builder", "templates", "preflight.py")
SKILLS_DIR = os.path.join(ROOT, "skills-library", ".claude", "skills")
CONFIG_MD = os.environ.get("CONFIG_MD") or os.path.join(SKILLS_DIR, "config.md")
CONFIG_EXAMPLE = os.path.join(SKILLS_DIR, "config.example.md")
EXTENSIONS_DIR = os.path.join(ROOT, "extensions")


def _norm_key(k):
    return re.sub(r"\s+", "_", k.strip()).upper()


def _read_config(path):
    """Same rules as preflight.py / fda_common.py: `| KEY | `value` |` rows and `Key: value` lines."""
    cfg = {}
    if path and os.path.exists(path):
        for line in open(path, encoding="utf-8", errors="replace"):
            m = re.match(r"\|\s*([A-Za-z][A-Za-z0-9_ ]*?)\s*\|\s*`([^`]*)`", line)
            if m:
                k, v = _norm_key(m.group(1)), m.group(2).strip()
            else:
                m = re.match(r"^\s*([A-Za-z][A-Za-z0-9_]*(?: [A-Za-z0-9_]+){0,2})\s*:\s*(.*?)\s*$", line)
                if not m or _norm_key(m.group(1)) in cfg:
                    continue
                k, v = _norm_key(m.group(1)), m.group(2)
            if re.fullmatch(r"<[^>]*>", v):     # `<placeholder>` = unset
                continue
            cfg[k] = v
    return cfg


CFG = _read_config(CONFIG_MD)


def cfg(key, default=""):
    return CFG.get(_norm_key(key), default).strip().strip('"')


def resolve_tool(env_name, cfg_key, names):
    for cand in (os.environ.get(env_name, ""), cfg(cfg_key)):
        if cand and (os.path.exists(cand) or shutil.which(cand)):
            return cand
    for n in names:
        p = shutil.which(n)
        if p:
            return p
    return ""


def run(cmd, timeout=None, env=None, cwd=None):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd,
                           encoding="utf-8", errors="replace")
        return r.returncode, ANSI.sub("", (r.stdout or "") + (r.stderr or ""))
    except FileNotFoundError:
        return -1, "not found: %s" % (cmd[0] if cmd else "")
    except subprocess.TimeoutExpired:
        return -1, "timed out"
    except OSError as e:
        return -1, str(e)


def pg_conn():
    return dict(host=os.environ.get("PG_HOST") or cfg("PG_HOST", "localhost") or "localhost",
                port=os.environ.get("PG_PORT") or cfg("PG_PORT", "5432") or "5432",
                user=os.environ.get("PG_USER") or cfg("PG_USER", "postgres") or "postgres",
                pwd=os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or cfg("PG_PASSWORD"))


# ----------------------------------------------------------------- sample resolution
def list_samples():
    out = []
    for d in sorted(glob.glob(os.path.join(HERE, "*", "*", "*"))):
        if os.path.isdir(d) and os.path.exists(os.path.join(d, "database.sql")) and glob.glob(os.path.join(d, "*.flogo")):
            out.append(d)
    return out


def resolve_sample(name):
    if not name:
        return None
    if os.path.isdir(name) and glob.glob(os.path.join(name, "*.flogo")):
        return os.path.abspath(name)
    samples = list_samples()
    for d in samples:
        if os.path.basename(d).lower() == name.lower():
            return d
    hits = [d for d in samples if name.lower() in os.path.basename(d).lower()]
    return hits[0] if len(hits) == 1 else None


def mcp_flogo(sample):
    hits = glob.glob(os.path.join(sample, "*MCPServer.flogo")) or glob.glob(os.path.join(sample, "*MCP*.flogo"))
    return hits[0] if hits else None


def db_name(sample):
    f = mcp_flogo(sample)
    if f:
        try:
            for p in json.load(open(f, encoding="utf-8")).get("properties", []):
                if isinstance(p, dict) and p.get("name") == "PostgreSQL.PostgresConn.Database_Name":
                    return str(p.get("value", "")).strip()
        except Exception:
            pass
    return ""


def is_rag(sample):
    if "rag" in os.path.basename(sample).lower():
        return True
    for f in glob.glob(os.path.join(sample, "*.flogo")):
        try:
            if "vectorsearch" in open(f, encoding="utf-8", errors="replace").read().lower():
                return True
        except Exception:
            pass
    return False


# ----------------------------------------------------------------- steps
def step_check():
    hdr("check : prerequisites (preflight)")
    if not os.path.exists(PREFLIGHT):
        say("! preflight.py not found at %s" % PREFLIGHT)
        return False
    rc, out = run([sys.executable, PREFLIGHT, "--need", "db,build"], timeout=300)
    say(out.strip())
    return rc == 0


def step_config():
    hdr("config : config.md")
    if not os.path.exists(CONFIG_MD):
        if os.path.exists(CONFIG_EXAMPLE):
            shutil.copyfile(CONFIG_EXAMPLE, CONFIG_MD)
            say("Created %s from config.example.md." % CONFIG_MD)
            say("Fill in: PG_PASSWORD, API_Key, LLM_Model, FLOGOBUILD_PATH (or PATH), VSIX_FILE_PATH, PSQL_PATH -- then re-run.")
        else:
            say("! config.md and config.example.md are both missing under %s" % SKILLS_DIR)
        return False
    say("config.md: %s" % CONFIG_MD)
    missing = [k for k in ("PG_PASSWORD", "API_Key", "LLM_Model") if not cfg(k)]
    if missing:
        say("! missing or still a <placeholder> in config.md: %s" % ", ".join(missing))
        return False
    say("required keys present: PG_PASSWORD, API_Key, LLM_Model (values hidden).")
    return True


def step_validate():
    hdr("validate : PostgreSQL connection + LLM key/model")
    ok = True

    psql = resolve_tool("PSQL", "PSQL_PATH", ["psql"])
    if not psql:
        say("! psql not found (set PSQL_PATH in config.md or add it to PATH).")
        ok = False
    else:
        c = pg_conn()
        if not c["pwd"]:
            say("! no PostgreSQL password (PG_PASSWORD).")
            ok = False
        else:
            env = dict(os.environ, PGPASSWORD=c["pwd"], PGCONNECT_TIMEOUT="5")
            rc, out = run([psql, "-h", c["host"], "-p", c["port"], "-U", c["user"], "-d", "postgres",
                           "-w", "-tA", "-c", "SELECT 1"], timeout=30, env=env)
            if rc == 0 and "1" in out:
                say("PostgreSQL connection OK: %s@%s:%s" % (c["user"], c["host"], c["port"]))
            else:
                say("! PostgreSQL connection FAILED (%s@%s:%s): %s" % (c["user"], c["host"], c["port"], out.strip()[:160]))
                ok = False

    key = os.environ.get("LLM_API_KEY") or cfg("API_Key")
    model = os.environ.get("LLM_MODEL") or cfg("LLM_Model")
    base = (cfg("LLM_Base_URL") or "https://api.openai.com/v1").rstrip("/")
    if not key:
        say("! no LLM API key (API_Key) to validate.")
        ok = False
    else:
        try:
            req = urllib.request.Request(base + "/models", headers={"Authorization": "Bearer " + key})
            with urllib.request.urlopen(req, timeout=20) as r:
                data = json.loads(r.read().decode("utf-8", "replace"))
            ids = [m.get("id") for m in data.get("data", []) if isinstance(m, dict)]
            say("LLM key OK (%d models available to this key)." % len(ids))
            if model and model in ids:
                say("LLM model '%s' available." % model)
            elif model:
                caps = sorted(i for i in ids if i and re.search(r"gpt-|^o\d|sonnet|opus|gemini|llama|mistral", i, re.I))
                say("! LLM model '%s' is not in this key's /models list -- it may still be usable; verify, or pick one of: %s"
                    % (model, ", ".join(caps[:8]) or "(none matched)"))
            else:
                say("! LLM_Model is not set in config.md.")
        except urllib.error.HTTPError as e:
            say("! LLM key check failed: HTTP %s%s" % (e.code, " (check API_Key / LLM_Base_URL)"))
            if e.code in (401, 403):
                ok = False
        except Exception as e:
            say("! LLM key check could not run (%s) -- network/provider issue, not treating as fatal: %s"
                % (type(e).__name__, str(e)[:120]))
    return ok


def _flogobuild():
    return resolve_tool("FLOGOBUILD", "FLOGOBUILD_PATH", ["flogobuild"])


def _list_contexts(fb):
    rc, out = run([fb, "list-context"], timeout=90)
    ctxs = re.findall(r'"([^"]+)"\s*:\s*\{', out)
    default = re.search(r"Default Context:\s*(\S+)", out)
    return ctxs, (default.group(1) if default else "")


def ensure_context(sample, forced):
    hdr("context : flogobuild build context")
    fb = _flogobuild()
    if not fb:
        say("! flogobuild not found (set FLOGOBUILD_PATH in config.md or add it to PATH).")
        return None, False
    ctxs, default = _list_contexts(fb)
    vsix = cfg("VSIX_FILE_PATH")

    if forced:
        if forced in ctxs:
            say("Using context '%s'." % forced)
            return forced, True
        say("! requested --context '%s' not found. Available: %s" % (forced, ", ".join(ctxs) or "(none)"))
        return None, False

    if is_rag(sample):
        name = "flogo-ext-openai"
        if name in ctxs:
            say("Using extension-aware context '%s' (RAG sample)." % name)
            return name, True
        if not (vsix and os.path.exists(vsix)):
            say("! RAG sample needs an extension-aware context, and VSIX_FILE_PATH is not set/valid.")
            say("  Create one: flogobuild create-context -n %s -v <flogo.vsix> -u \"%s\" --set-default" % (name, EXTENSIONS_DIR))
            return None, False
        say("Creating extension-aware context '%s' (this can take a few minutes) ..." % name)
        rc, out = run([fb, "create-context", "-n", name, "-v", vsix, "-u", EXTENSIONS_DIR, "--set-default"], timeout=1800)
        if rc != 0:
            say("! create-context failed: %s" % out.strip()[-500:])
            return None, False
        say("Created context '%s'." % name)
        return name, True

    want = cfg("FLOGOBUILD_CONTEXT_NAME")
    if want and want in ctxs:
        say("Using context '%s'." % want)
        return want, True
    if default and default.lower() != "none":
        say("Using default context '%s'." % default)
        return default, True
    if ctxs:
        say("Using context '%s'." % ctxs[0])
        return ctxs[0], True
    if not (vsix and os.path.exists(vsix)):
        say("! no build context exists and VSIX_FILE_PATH is not set/valid.")
        say("  Create one: flogobuild create-context -n flogo-ctx -v <flogo.vsix> --set-default")
        return None, False
    say("Creating context 'flogo-ctx' from the Flogo VSIX (this can take a few minutes) ...")
    rc, out = run([fb, "create-context", "-n", "flogo-ctx", "-v", vsix, "--set-default"], timeout=1800)
    if rc != 0:
        say("! create-context failed: %s" % out.strip()[-500:])
        return None, False
    say("Created context 'flogo-ctx'.")
    return "flogo-ctx", True


def _pg_tool(psql, name):
    """createdb / dropdb sit next to psql; fall back to PATH."""
    if psql and (os.sep in psql or (os.altsep and os.altsep in psql)):
        cand = os.path.join(os.path.dirname(psql), name + (".exe" if os.name == "nt" else ""))
        if os.path.exists(cand):
            return cand
    return name


def step_db(sample, force):
    hdr("db : create + load the database")
    db = db_name(sample)
    if not db:
        say("! could not read the database name from the MCP .flogo.")
        return False
    psql = resolve_tool("PSQL", "PSQL_PATH", ["psql"])
    if not psql:
        say("! psql not found.")
        return False
    c = pg_conn()
    env = dict(os.environ, PGPASSWORD=c["pwd"] or "")
    common = ["-h", c["host"], "-p", c["port"], "-U", c["user"], "-w"]

    rc, out = run([psql] + common + ["-d", "postgres", "-tA", "-c",
                   "SELECT 1 FROM pg_database WHERE datname='%s'" % db], timeout=30, env=env)
    exists = out.strip().startswith("1")
    if exists and not force:
        say("Database '%s' already exists -- leaving it (use --force-db to drop & recreate)." % db)
    else:
        if exists and force:
            say("Dropping existing database '%s' ..." % db)
            rc, out = run([_pg_tool(psql, "dropdb")] + common + [db], timeout=120, env=env)
            if rc != 0:
                say("! dropdb failed: %s" % out.strip()[:200])
                return False
        say("Creating database '%s' ..." % db)
        rc, out = run([_pg_tool(psql, "createdb")] + common + [db], timeout=120, env=env)
        if rc != 0:
            say("! createdb failed: %s" % out.strip()[:200])
            return False

    say("Loading database.sql (includes seed_data.sql) ...")
    rc, out = run([psql] + common + ["-d", db, "-v", "ON_ERROR_STOP=1", "-f", "database.sql"],
                  timeout=600, env=env, cwd=sample)
    if rc != 0:
        say("! database.sql load failed: %s" % out.strip()[-500:])
        return False
    say("Database '%s' is loaded." % db)
    return True


# property name in the .flogo  <-  config.md key, default, type
CRED_MAP = [
    ("PostgreSQL.PostgresConn.Host", "PG_HOST", "localhost", "str"),
    ("PostgreSQL.PostgresConn.Port", "PG_PORT", "5432", "int"),
    ("PostgreSQL.PostgresConn.User", "PG_USER", "postgres", "str"),
    ("PostgreSQL.PostgresConn.Password", "PG_PASSWORD", "", "str"),
    ("AgenticAI.OpenAIConn.API_Key", "API_Key", "", "str"),
    ("AgenticAI.OpenAIConn.LLM_Provider", "LLM_Provider", "OpenAI", "str"),
    ("LLM_Model", "LLM_Model", "", "str"),
    ("Email_Username", "Username", "", "str"),
    ("Email_App_Password", "Password", "", "str"),
]


def _inject(flogo_path):
    """Set credential app-property values from config.md, in place, on a build COPY only."""
    d = json.load(open(flogo_path, encoding="utf-8"))
    byname = {p.get("name"): p for p in d.get("properties", []) if isinstance(p, dict)}
    for pname, ckey, default, typ in CRED_MAP:
        if pname not in byname:
            continue
        val = cfg(ckey, default)
        if val == "":                       # don't overwrite with empty (e.g. email not configured)
            continue
        if typ == "int":
            try:
                val = int(val)
            except ValueError:
                continue
        byname[pname]["value"] = val
    json.dump(d, open(flogo_path, "w", encoding="utf-8"), indent=2)


def step_build(sample, context):
    hdr("build : build runnable executables into ./bin")
    fb = _flogobuild()
    if not fb:
        say("! flogobuild not found.")
        return False
    if not context:
        say("! no build context resolved (run the 'context' step first).")
        return False
    apps = sorted(glob.glob(os.path.join(sample, "*.flogo")))
    if not apps:
        say("! no .flogo apps found in the sample.")
        return False
    bindir = os.path.join(sample, "bin")
    os.makedirs(bindir, exist_ok=True)

    ok = True
    for app in apps:
        name = os.path.basename(app)
        dst = os.path.join(bindir, name)
        shutil.copyfile(app, dst)
        _inject(dst)
        say("Building %s (context '%s') ..." % (name, context))
        rc, out = run([fb, "build-exe", "-f", os.path.join("bin", name), "-c", context, "-o", "bin"],
                      timeout=1800, cwd=sample)
        stem = name[:-6]        # strip ".flogo"
        exe = os.path.join(bindir, stem + (".exe" if os.name == "nt" else ""))
        if rc == 0 and os.path.exists(exe):
            say("  built %s" % os.path.basename(exe))
        else:
            say("  ! build FAILED for %s: %s" % (name, out.strip()[-600:]))
            ok = False
    if ok:
        say("")
        say("Executables are in: %s" % bindir)
        say("They have your credentials baked in (./bin is git-ignored; the committed .flogo stay scrubbed).")
        say("Start them YOURSELF in order -- MCP Server -> Agents -> Orchestrator -- then connect the Chatbot.")
        say("See RUNNING_THE_SAMPLES.md.")
    return ok


# ----------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sample", nargs="?", help="sample folder name (or path) under Industry_Use_Cases/")
    ap.add_argument("--list", action="store_true", help="list available samples and exit")
    ap.add_argument("--steps", default="all", help="comma list from: " + ",".join(ALL_STEPS) + " (default all)")
    ap.add_argument("--force-db", action="store_true", help="drop & recreate the sample database")
    ap.add_argument("--context", default="", help="force a specific flogobuild context name")
    a = ap.parse_args()

    if a.list:
        say("Samples under Industry_Use_Cases/:")
        for d in list_samples():
            say("  " + os.path.relpath(d, HERE).replace(os.sep, "/"))
        return 0

    steps = ALL_STEPS if a.steps == "all" else [s.strip().lower() for s in a.steps.split(",") if s.strip()]
    bad = [s for s in steps if s not in ALL_STEPS]
    if bad:
        ap.error("unknown step(s): %s; choose from %s" % (bad, ALL_STEPS))

    sample = None
    if a.sample or any(s in steps for s in ("context", "db", "build")):
        sample = resolve_sample(a.sample)
        if not sample:
            ap.error("sample not found: %r  (try --list)" % a.sample)

    say("Setup helper for the Industry Use-Case samples")
    say("repo: %s" % ROOT)
    if sample:
        say("sample: %s   (database: %s%s)" % (os.path.basename(sample), db_name(sample) or "?",
                                               ", RAG" if is_rag(sample) else ""))

    results, context, skipped = {}, None, False
    for s in steps:
        if skipped:
            results[s] = None
            continue
        if s == "check":
            results[s] = step_check()
        elif s == "config":
            results[s] = step_config()
        elif s == "validate":
            results[s] = step_validate()
        elif s == "context":
            context, results[s] = ensure_context(sample, a.context)
        elif s == "db":
            results[s] = step_db(sample, a.force_db)
        elif s == "build":
            if context is None:
                context, cok = ensure_context(sample, a.context)
                if not cok:
                    results[s] = False
                    break
            results[s] = step_build(sample, context)
        if results[s] is False:
            skipped = True      # stop the chain; report the rest as skipped

    hdr("summary")
    for s in steps:
        state = {True: "OK", False: "FAILED", None: "skipped"}[results.get(s)]
        say("  %-9s %s" % (s, state))
    failed = any(results.get(s) is False for s in steps)
    if failed:
        say("\nFix the failed step above and re-run (you can re-run a subset with --steps).")
    else:
        say("\nSetup complete. Start the apps yourself and connect the Chatbot -- see RUNNING_THE_SAMPLES.md.")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
