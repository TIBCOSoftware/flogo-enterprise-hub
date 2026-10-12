#!/usr/bin/env python3
"""Preflight for the Flogo skills library: checks the prerequisites for what you are about to do.

  python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py                  # design only (fda)
  python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need db        # agentic use case: design + SQL rule tests
  python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need build,chat  # executables + chat e2e
  python skills-library/.claude/skills/agentic-ai-use-case-builder/templates/preflight.py --need deploy    # TIBCO Platform deploy

Stdlib only; runs on Windows, macOS and Linux; ASCII output; exit code 0 = ready, 1 = a blocking check failed.
Design (always): fda - it ships inside the TIBCO Flogo VS Code extension - is the only blocking check.
--need db     -> config.md, Python >= 3.9, psql + a PostgreSQL connection block; LLM key / model / SMTP are WARN
--need build  -> flogobuild + a build context + the Go runtime (`go version`) + the LLM key block
                 (`test` is accepted as an alias of `build`: flogobuild test-app and the run ladder need built apps)
--need chat   -> Node.js >= 16 + the websocket-client package (`import websocket`) + the LLM key block
--need deploy -> tibcop + at least one profile (and config.md TIBCOP_PROFILE, if set, must match one) block
Scopes you did not ask for are not probed; they are listed as INFO "not needed for design".
Secrets (PG password, LLM key, SMTP password, tibcop tokens) are never printed.
Downloads: Flogo VS Code extension + flogobuild -> https://www.tibco.com/downloads/11810 ; Go -> https://go.dev/dl/
Install hints: skills-library/AGENT.md -> "Prerequisites and preflight".
"""
import argparse, glob, os, platform, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
DOC = "see skills-library/AGENT.md -> 'Prerequisites and preflight'"
NEEDS = ("db", "build", "chat", "deploy")
ALIASES = {"test": "build"}
SCOPE_ITEMS = {"db": "Python 3.9+, psql + PostgreSQL connection",
               "build": "flogobuild + build context + Go runtime",
               "chat": "Node.js + websocket-client",
               "deploy": "tibcop + profile"}
TIBCO_DL = "https://www.tibco.com/downloads/11810"
ADD_PROFILE = 'tibcop add-profile --name "<profile>" --cpurl https://<SUBSCRIPTION>.<REGION>.my.tibco.com'
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
results = []          # (status, label, detail, hint)


# ---------------------------------------------------------------- config.md (same rules as _rebuild/fda_common.py)
def find_config_md():
    if os.environ.get("CONFIG_MD"): return os.environ["CONFIG_MD"]
    d = HERE
    while True:
        for rel in (("skills-library", ".claude", "skills", "config.md"), (".claude", "skills", "config.md")):
            p = os.path.join(d, *rel)
            if os.path.exists(p): return p
        parent = os.path.dirname(d)
        if parent == d: return ""
        d = parent

def norm_key(k): return re.sub(r"\s+", "_", k.strip()).upper()

def read_config(path):
    """`| KEY | `value` |` rows and `Key: value` lines; keys case-insensitive, space == underscore; <placeholder> = unset."""
    cfg = {}
    if not path or not os.path.exists(path): return cfg
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\|\s*([A-Za-z][A-Za-z0-9_ ]*?)\s*\|\s*`([^`]*)`", line)
        if m: k, v = norm_key(m.group(1)), m.group(2).strip()
        else:
            m = re.match(r"^\s*([A-Za-z][A-Za-z0-9_]*(?: [A-Za-z0-9_]+){0,2})\s*:\s*(.*?)\s*$", line)
            if not m or norm_key(m.group(1)) in cfg: continue
            k, v = norm_key(m.group(1)), m.group(2)
        if re.fullmatch(r"<[^>]*>", v): continue
        cfg[k] = v
    return cfg

CONFIG_MD = find_config_md()
CFG = read_config(CONFIG_MD)
def cfg(key, default=""): return CFG.get(norm_key(key), default).strip().strip('"')


# ---------------------------------------------------------------- helpers
def add(status, label, detail="", hint=""):
    results.append((status, label, detail, hint))

def check(ok, blocking, label, detail, hint):
    add("OK" if ok else ("FAIL" if blocking else "WARN"), label, detail, "" if ok else hint)
    return ok

def run(cmd, timeout=60, env=None):
    """Return (returncode, combined output without ANSI colours); (-1, reason) if it can't start."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env,
                           encoding="utf-8", errors="replace")
        return r.returncode, ANSI.sub("", (r.stdout or "") + (r.stderr or "")).strip()
    except FileNotFoundError:
        return -1, "not found"
    except subprocess.TimeoutExpired:
        return -1, f"timed out after {timeout}s"
    except OSError as e:
        return -1, str(e)

def version_tuple(text):
    m = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    return tuple(int(x or 0) for x in m.groups()) if m else None

def resolve_tool(env_name, cfg_key, names):
    """env var > config.md path (if it exists) > PATH."""
    for cand in (os.environ.get(env_name, ""), cfg(cfg_key)):
        if cand and (os.path.exists(cand) or shutil.which(cand)): return cand
    for n in names:
        p = shutil.which(n)
        if p: return p
    return ""

def first_line(s, n=110):
    s = (s or "").strip().splitlines()
    return (s[0] if s else "")[:n]


# ---------------------------------------------------------------- design (always)
def check_platform():
    sysname, mach = platform.system(), platform.machine().lower()
    add("INFO", "Platform", f"{sysname} {platform.release()} ({mach})")
    if sysname == "Darwin" and mach in ("arm64", "aarch64"):
        add("INFO", "Apple Silicon", "M-series Macs: expected to work; not yet verified by the maintainers (flogobuild ships darwin_arm64; TIBCO EMS is not supported on ARM)")
    if os.name == "nt" and not shutil.which("bash"):
        add("WARN", "Git Bash", "bash not found on PATH (the skills' shell snippets are bash)",
            "install Git for Windows (https://git-scm.com/download/win) and run the skills from Git Bash")

def find_fda():
    """Same lookup as _rebuild/fda_common.py / AGENT.md: env FDA > `fda` on PATH > newest tibco.flogo-* extension."""
    if os.environ.get("FDA"): return os.environ["FDA"], ""
    p = shutil.which("fda")
    if p: return p, ""
    exe = "flogodesign-cli.exe" if os.name == "nt" else "flogodesign-cli"
    home = os.path.expanduser("~")
    for ext_dir in (".vscode", ".vscode-insiders", ".vscode-server"):
        hits = glob.glob(os.path.join(home, ext_dir, "extensions", "tibco.flogo-*", "bin", exe))
        if hits:
            best = max(hits, key=os.path.getmtime)
            m = re.search(r"tibco\.flogo-(\d+\.\d+\.\d+)", best)
            return best, (m.group(1) if m else "")
    p = cfg("FLOGODESIGN_CLI_PATH")
    if p and os.path.exists(p): return p, ""
    return "", ""

def check_fda():
    hint = ("install VS Code + the TIBCO Flogo VS Code extension 2.26.7+ (" + TIBCO_DL + " or "
            "https://marketplace.visualstudio.com/items?itemName=tibco.flogo) - fda (flogodesign-cli) ships inside "
            "the extension; nothing separate to install")
    path, ext_ver = find_fda()
    found = bool(path) and (os.path.exists(path) or bool(shutil.which(path)))
    if not check(found, True, "fda (flogodesign-cli)", (path + " (does not exist)") if path and not found else (path or "not found"), hint):
        return
    rc, out = run([path, "version"])
    ok = rc == 0 and "version" in out.lower()
    detail = f"{first_line(out)} | {path}"
    check(ok, True, "fda version", detail, hint)
    if ok and ext_ver:
        vt = version_tuple(ext_ver)
        if vt and vt < (2, 26, 7):
            add("WARN", "Flogo VS Code extension", f"{ext_ver} is older than 2.26.7 (the tested floor)", "update the TIBCO Flogo VS Code extension")
        else:
            add("OK", "Flogo VS Code extension", ext_ver)

def check_config(need):
    cp = "cp skills-library/.claude/skills/config.example.md skills-library/.claude/skills/config.md  # then fill it in"
    if not need:                                     # design only: config.md is helpful but not required
        if CONFIG_MD: add("INFO", "config.md", CONFIG_MD)
        else: add("WARN", "config.md", "not found (needed before --need db/build/chat/deploy)", cp)
        return
    if not check(bool(CONFIG_MD) and os.path.exists(CONFIG_MD), True, "config.md", CONFIG_MD or "not found", cp):
        return
    if not ({"db", "build", "chat"} & need):
        return                                       # deploy only: LLM / SMTP settings are not relevant
    key = os.environ.get("LLM_API_KEY") or cfg("API_Key")
    check(bool(key), bool({"build", "chat"} & need), "LLM API key",
          "set (value hidden)" if key else "API_Key is empty or still a <placeholder>",
          "set API_Key in config.md (or env LLM_API_KEY)")
    model = os.environ.get("LLM_MODEL") or cfg("LLM_Model")
    if not model:
        add("WARN", "LLM model", "LLM_Model not set", "set LLM_Model: gpt-5.5 (or another capable tool-calling model) in config.md")
    elif "nano" in model.lower():
        add("WARN", "LLM model", f"{model} - nano-class models drop tool calls and fail to delegate",
            "use a capable tool-calling model such as gpt-5.5 for orchestrators (config.md LLM_Model)")
    else:
        add("OK", "LLM model", model)
    smtp = [k for k in ("Server", "Username", "Password") if not cfg(k)]
    if smtp:
        add("WARN", "SMTP (email tools only)", "missing: " + ", ".join(smtp),
            "only needed for email tools; Gmail needs an app password: https://support.google.com/accounts/answer/185833")
    else:
        add("OK", "SMTP (email tools only)", f"{cfg('Server')}:{cfg('Port') or '?'} (password hidden)")


# ---------------------------------------------------------------- --need db
def check_python():
    v = sys.version_info
    check(v >= (3, 9), True, "Python", f"{platform.python_version()} ({sys.executable})",
          "install Python 3.9+ from https://www.python.org/downloads/ (macOS: brew install python; Linux: distro package)")

def check_psql():
    hint = ("install PostgreSQL 14+ and its psql client (Windows: https://www.postgresql.org/download/windows/ ; "
            "macOS: brew install postgresql@16 ; Linux: apt install postgresql-client) and put psql on PATH, "
            "or set env PSQL / config.md PSQL_PATH")
    path = resolve_tool("PSQL", "PSQL_PATH", ["psql"])
    if not check(bool(path), True, "psql", path or "not found", hint): return
    rc, out = run([path, "--version"], timeout=20)
    check(rc == 0, True, "psql version", f"{first_line(out)} | {path}", hint)
    host = os.environ.get("PG_HOST") or cfg("PG_HOST", "localhost") or "localhost"
    port = os.environ.get("PG_PORT") or cfg("PG_PORT", "5432") or "5432"
    user = os.environ.get("PG_USER") or cfg("PG_USER", "postgres") or "postgres"
    db = os.environ.get("PG_DB") or "postgres"
    pwd = os.environ.get("PG_PWD") or os.environ.get("PG_PASSWORD") or cfg("PG_PASSWORD")
    if not check(bool(pwd), True, "PostgreSQL password", "set (value hidden)" if pwd else "not set",
                 "export PG_PWD (or PG_PASSWORD), or fill PG_PASSWORD in config.md"):
        return
    env = dict(os.environ, PGPASSWORD=pwd, PGCONNECT_TIMEOUT="5")
    rc, out = run([path, "-h", host, "-p", port, "-U", user, "-d", db, "-w", "-tA", "-c",
                   "SELECT current_setting('server_version_num')"], timeout=30, env=env)
    where = f"{user}@{host}:{port}/{db}"
    if not check(rc == 0, True, "PostgreSQL SELECT 1", where if rc == 0 else f"{where}: {first_line(out, 160)}",
                 "start the PostgreSQL server and check PG_HOST/PG_PORT/PG_USER/PG_PASSWORD in config.md"):
        return
    num = re.search(r"\d{5,6}", out)
    if num and int(num.group(0)) < 140000:
        add("WARN", "PostgreSQL server version", num.group(0), "PostgreSQL 14+ is the tested floor")
    elif num:
        add("OK", "PostgreSQL server version", f"{int(num.group(0)) // 10000}.x")


# ---------------------------------------------------------------- --need build
def check_flogobuild():
    hint = ("download the Flogo App Build CLI (flogobuild) from " + TIBCO_DL + " (not bundled in the VS Code "
            "extension); unzip it and put <os>_<arch>/flogobuild on PATH or set FLOGOBUILD_PATH in config.md")
    path = resolve_tool("FLOGOBUILD", "FLOGOBUILD_PATH", ["flogobuild"])
    if not check(bool(path), True, "flogobuild", path or "not found", hint): return
    rc, out = run([path, "version"])
    ver = re.search(r'"version"\s*:\s*"([^"]+)"', out)
    if not check(rc == 0, True, "flogobuild version", f"{ver.group(1) if ver else first_line(out)} | {path}", hint): return
    rc, out = run([path, "list-context"])
    ctxs = re.findall(r'^\s*"([^"]+)"\s*:\s*\{', out, re.M)
    default = re.search(r"Default Context:\s*(\S+)", out)
    check(rc == 0 and bool(ctxs), True, "flogobuild context",
          f"{len(ctxs)} context(s), default: {default.group(1) if default else 'none'}" if ctxs else "no build context",
          "flogobuild create-context -n <name-without-dots> -v <path-to-flogo-vsix> --set-default "
          "(names: letters/digits/_/-, 3-30 chars, no dots)")
    want = cfg("FLOGOBUILD_CONTEXT_NAME")
    if ctxs and want and want not in ctxs:
        add("WARN", "FLOGOBUILD_CONTEXT_NAME", f"'{want}' (config.md) is not in list-context",
            "set FLOGOBUILD_CONTEXT_NAME to one of: " + ", ".join(ctxs[:5]))

def check_go():
    hint = "building Flogo apps requires the Go runtime 1.25.7+ (Flogo 2.26.8 installation guide): install Go from https://go.dev/dl/ and put `go` on PATH (or set env GO)"
    path = resolve_tool("GO", "GO_PATH", ["go"])
    if not check(bool(path), True, "Go runtime", path or "not found", hint): return
    rc, out = run([path, "version"], timeout=30)
    check(rc == 0 and "go version" in out, True, "Go version", f"{first_line(out)} | {path}", hint)


# ---------------------------------------------------------------- --need chat
def check_chat():
    try:
        import websocket  # noqa: F401  (pip install websocket-client)
        add("OK", "websocket-client", "importable")
    except ImportError:
        check(False, True, "websocket-client", "import websocket failed",
              f"{os.path.basename(sys.executable)} -m pip install websocket-client")
    hint = "install Node.js 16+ from https://nodejs.org/ (macOS: brew install node; Linux: distro package or nvm)"
    path = shutil.which("node")
    if not check(bool(path), True, "Node.js", path or "not found", hint): return
    rc, out = run([path, "-v"], timeout=20)
    vt = version_tuple(out)
    check(rc == 0 and bool(vt) and vt >= (16, 0, 0), True, "Node.js version", f"{first_line(out)} | {path}", hint)


# ---------------------------------------------------------------- --need deploy
def check_tibcop():
    hint = ("install the TIBCO Platform CLI (tibcop) and put it on PATH or set TIBCOP_PATH; then " + ADD_PROFILE +
            " [--software-statement <software_statement>]")
    path = resolve_tool("TIBCOP", "TIBCOP_PATH", ["tibcop"])
    if not check(bool(path), True, "tibcop", path or "not found", hint): return
    rc, out = run([path, "--version"], timeout=90)
    if not check(rc == 0, True, "tibcop version", f"{first_line(out)} | {path}", hint): return
    rc, out = run([path, "list-profiles"], timeout=90)          # output includes token expiry lines: never print it raw
    names = re.findall(r"Profile Name:\s*(\S+)", out) if rc == 0 else []
    check(bool(names), True, "tibcop profile", f"{len(names)} profile(s): {', '.join(names)}" if names else "no profiles",
          ADD_PROFILE + "; then `tibcop list-profiles` and set TIBCOP_PROFILE in config.md")
    profile = cfg("TIBCOP_PROFILE")
    if names and profile:
        check(profile in names, True, "TIBCOP_PROFILE",
              f"'{profile}' (config.md)" + ("" if profile in names else " is not a configured profile"),
              "set TIBCOP_PROFILE in config.md to one of: " + ", ".join(names) + " (or create it: " + ADD_PROFILE + ")")
    elif names:
        add("WARN", "TIBCOP_PROFILE", "not set in config.md (tibcop uses its default profile)",
            "set TIBCOP_PROFILE (flogo-deploy passes it as --profile)")


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--need", default="", help="comma list of extra blocking scopes: " + ",".join(NEEDS) +
                    " (no --need = design only: fda)")
    a = ap.parse_args()
    need = {ALIASES.get(x, x) for x in (y.strip().lower() for y in a.need.split(",")) if x}
    if need - set(NEEDS):
        ap.error(f"unknown --need value(s): {sorted(need - set(NEEDS))}; choose from {','.join(NEEDS)}")

    print("Flogo skills preflight  (blocking scopes: design" + "".join("," + n for n in NEEDS if n in need) + ")")
    check_platform()
    check_fda()
    check_config(need)
    if "db" in need: check_python(); check_psql()
    if "build" in need: check_flogobuild(); check_go()
    if "chat" in need: check_chat()
    if "deploy" in need: check_tibcop()
    for n in NEEDS:
        if n not in need:
            add("INFO", SCOPE_ITEMS[n], f"not needed for design (add --need {n} to check)")

    for status, label, detail, hint in results:
        line = f"[{status:<4}] {label}" + (f": {detail}" if detail else "")
        print(line.encode("ascii", "replace").decode("ascii"))
        if hint:
            print(f"       fix: {hint}".encode("ascii", "replace").decode("ascii"))
            print(f"       {DOC}")
    fails = sum(1 for r in results if r[0] == "FAIL")
    warns = sum(1 for r in results if r[0] == "WARN")
    oks = sum(1 for r in results if r[0] == "OK")
    print(f"\nSummary: {oks} ok, {warns} warn, {fails} blocking fail -> " + ("NOT READY" if fails else "READY"))
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
