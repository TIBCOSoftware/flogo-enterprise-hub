#!/usr/bin/env bash
# Create (or drop) the ActiveSpaces 5.2 vector table used by TelecomPolicyKnowledgeHub.flogo.
#
#   ./scripts/create_vector_table.sh            create telecore_policy_kb if it does not exist
#   ./scripts/create_vector_table.sh --drop     drop it (deletes every ingested chunk)
#
# Columns match the Vector Upsert mapping in the app: key (primary key), content, metadata,
# embedding. 1536 dimensions = OpenAI text-embedding-3-small, the ChunkAndEmbed default.
#
# Environment overrides: AS_GRID_URL (default http://localhost:52080), AS_TABLE, AS_VECTOR_DIM,
# TIBDG_ROOT (default /opt/tibco/as/5.2).
set -eu

URL="${AS_GRID_URL:-http://localhost:52080}"
TABLE="${AS_TABLE:-telecore_policy_kb}"
DIM="${AS_VECTOR_DIM:-1536}"
export TIBDG_ROOT="${TIBDG_ROOT:-/opt/tibco/as/5.2}"
PATH="$TIBDG_ROOT/bin:$PATH"

command -v tibdg >/dev/null || { echo "tibdg not found - set TIBDG_ROOT to your ActiveSpaces 5.2 install" >&2; exit 1; }

exists() { tibdg -r "$URL" table list 2>/dev/null | grep -q "^$TABLE ("; }

if [ "${1:-}" = "--drop" ]; then
    if exists; then tibdg -r "$URL" table delete "$TABLE" && echo "dropped $TABLE"; else echo "$TABLE does not exist"; fi
    exit 0
fi

if exists; then
    echo "$TABLE already exists - leaving it alone"
else
    tibdg -r "$URL" -s - <<EOF
table create $TABLE key string
column create $TABLE content string
column create $TABLE metadata string
column create $TABLE embedding vector_float32[$DIM]
EOF
    echo "created $TABLE (key, content, metadata, embedding[$DIM])"
fi
tibdg -r "$URL" table list | grep "^$TABLE ("
