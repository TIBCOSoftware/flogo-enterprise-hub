"""Build AutoInsuranceRAGIngestion.flogo (hybrid clone) for the Copperleaf Auto Insurance RAG use case.

Clones an earlier (pre-governance) AutoInsuranceRAGIngestion.flogo donor (not included in this repository) and
swaps fields surgically:
  - app name/description (Copperleaf), INGEST_PORT 9919 (`POST /ingest` kept), endpoint metadata port
  - PostgreSQL Database_Name = auto_insurance_governed, password = plain app property (like fda_common writes it)
  - POLICY_DOCS_DIR = ./policy_docs (relative: run the ingestion app from the sample folder, or override with an absolute path), the 4 regenerated PDF names in Upload1..Upload4
  - vector store name CopperleafAutoPolicyKB, OPENAI_API_KEY (live, read from config.md at run time),
    OPENAI_API_ENDPOINT_URL = https://api.openai.com/v1
  - a freshly minted PostgreSQL connection UUID (every conn:// reference updated)
  - the legacy literal INSERT replaced by the guarded INSERT ... SELECT * FROM record_vector_store(...), baked with
    App.bake_pg (fda sa) so Fields / State / schemas follow the parameters-mode contract.
The `contrib` blob, imports and the openAI tasks are carried verbatim.

Usage:  python build_ingestion.py [--force] [--out <path.flogo>]
"""
import argparse, json, os, sys, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fda_common as fc  # noqa: E402

USE_CASE_DIR = os.path.dirname(HERE)
SAMPLES_DIR = os.path.abspath(os.path.join(USE_CASE_DIR, "..", "..", "..", ".."))    # .../Agentic_AI
# The pre-governance ingestion donor is not included in this repository; set LEGACY_INGESTION
# to a local copy of the original AutoInsuranceRAGIngestion.flogo to rebuild.
LEGACY = os.environ.get("LEGACY_INGESTION", "")
TARGET = os.path.join(USE_CASE_DIR, "AutoInsuranceRAGIngestion.flogo")

APP_NAME = "AutoInsuranceRAGIngestion"
STORE_NAME = "CopperleafAutoPolicyKB"
PORT = 9919
DB_NAME = "auto_insurance_governed"
DOCS_DIR = os.path.join(USE_CASE_DIR, "policy_docs").replace("\\", "/")   # used only to check the PDFs exist
DOCS_DIR_PROP = os.environ.get("POLICY_DOCS_DIR", "./policy_docs")           # value written into the app
OPENAI_URL = "https://api.openai.com/v1"
FILES = {  # legacy upload task -> new PDF
    "Upload1": "Full_Coverage_Auto_Policy_Wording.pdf",
    "Upload2": "Liability_Comprehensive_Policy_Wording.pdf",
    "Upload3": "Auto_Endorsements_and_AddOns.pdf",
    "Upload4": "Claims_Procedure_Guide.pdf",
}
FLOW, INSERT_TASK = "IngestPolicyDocs", "RecordIndex"
GUARDED_INSERT = ("INSERT INTO document_index (vector_store_id, store_name, files_ingested) "
                  "SELECT * FROM record_vector_store(CAST(?w_vs AS text), CAST(?w_name AS text), "
                  "CAST(?w_files AS text));")
INSERT_PARAMS = [("w_vs", "=$activity[CreateVectorStore].id"),      # legacy: ?vs_id1 <- CreateVectorStore.id
                 ("w_name", "=$activity[CreateVectorStore].name"),  # legacy: literal store name
                 ("w_files", "4")]                                   # legacy: literal 4 (Return also says 4)
DESCRIPTION = ("Copperleaf Auto Insurance RAG ingestion (run once): create the OpenAI vector store "
               f"{STORE_NAME}, upload the 4 policy-wording PDFs (OpenAI chunks and embeds them), confirm via the "
               "file list, and record the vector store id in PostgreSQL document_index through the guarded "
               "record_vector_store() function for the search_policy_wording MCP tool.")


def walk_replace(node, old, new):
    """Replace a substring in every string value of a JSON tree."""
    if isinstance(node, dict):
        return {k: walk_replace(v, old, new) for k, v in node.items()}
    if isinstance(node, list):
        return [walk_replace(v, old, new) for v in node]
    return node.replace(old, new) if isinstance(node, str) else node


def task(d, tid):
    return next(t for r in d["resources"] if r["id"] == "flow:" + FLOW for t in r["data"]["tasks"] if t["id"] == tid)


def clone(out):
    if not LEGACY or not os.path.exists(LEGACY):
        raise SystemExit(f"pre-governance ingestion donor not found: {LEGACY!r}. "
                         "Set LEGACY_INGESTION to a local copy of the original AutoInsuranceRAGIngestion.flogo.")
    d = json.load(open(LEGACY, encoding="utf-8"))

    # fresh connection id, every conn:// reference follows
    (old_id,) = list(d["connections"].keys())
    new_id = str(uuid.uuid4())
    d = walk_replace(d, old_id, new_id)                               # values only (id, conn:// refs)
    d["connections"] = {new_id: d["connections"][old_id]}             # ...and the dict key
    d = walk_replace(d, "AutoPolicyKnowledgeBase", STORE_NAME)       # store name input + body sample

    d["name"], d["description"] = APP_NAME, DESCRIPTION
    props = {p["name"]: p for p in d["properties"]}
    props["PostgreSQL.PostgresConn.Host"]["value"] = fc.PG["host"]
    props["PostgreSQL.PostgresConn.Port"]["value"] = int(fc.PG["port"])
    props["PostgreSQL.PostgresConn.Database_Name"]["value"] = DB_NAME
    props["PostgreSQL.PostgresConn.User"]["value"] = fc.PG["user"]
    props["PostgreSQL.PostgresConn.Password"].update(type="string", value=fc.pg_password())
    props["OPENAI_API_KEY"].update(type="string", value=fc.llm_key())
    props["OPENAI_API_ENDPOINT_URL"]["value"] = OPENAI_URL
    props["POLICY_DOCS_DIR"]["value"] = DOCS_DIR_PROP
    props["INGEST_PORT"]["value"] = PORT

    for ep in d.get("metadata", {}).get("endpoints", []):
        ep["port"] = str(PORT)

    for tid, fname in FILES.items():
        task(d, tid)["activity"]["input"]["filename"] = f'=string.concat($property["POLICY_DOCS_DIR"],"/{fname}")'
    task(d, "CreateVectorStore")["activity"]["input"]["description"] = \
        "Copperleaf Auto Insurance policy wording knowledge base"

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print(f"  cloned -> {out} (connection {new_id})")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="overwrite an existing target")
    ap.add_argument("--out", default=TARGET)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    if os.path.exists(out) and not a.force:
        sys.exit(f"REFUSING: {out} exists (use --force). Never regenerate an app opened in the designer.")
    if not os.path.isdir(DOCS_DIR):
        sys.exit(f"missing {DOCS_DIR}: run generate_policy_pdfs.py first")
    clone(out)

    app = fc.App.__new__(fc.App)          # target already written by clone(); skip App's exists-guard
    app.file = out
    app.bake_pg(FLOW, INSERT_TASK, "act_postgresql_insert", GUARDED_INSERT, INSERT_PARAMS)

    # `fda sa` re-derives `contrib` from its bundled connector catalog (older versions + an extra Default entry);
    # put the legacy blob and imports back verbatim.
    legacy = json.load(open(LEGACY, encoding="utf-8"))
    d = app.load()
    if d["contrib"] != legacy["contrib"] or d["imports"] != legacy["imports"]:
        d["contrib"], d["imports"] = legacy["contrib"], legacy["imports"]
        with open(out, "w", encoding="utf-8", newline="\n") as f:
            json.dump(d, f, indent=2, ensure_ascii=False)
        print("  restored legacy contrib/imports")
    inp = task(d, INSERT_TASK)["activity"]["input"]
    assert inp["Query"] == GUARDED_INSERT and inp["Connection"] == app.conn_ref("PostgresConn")
    assert [f["FieldName"] for f in inp["Fields"]] == [p for p, _ in INSERT_PARAMS]
    print("Done:", out)


if __name__ == "__main__":
    main()
