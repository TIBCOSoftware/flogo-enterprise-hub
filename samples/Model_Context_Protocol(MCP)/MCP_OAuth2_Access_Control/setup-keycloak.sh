#!/usr/bin/env bash
#
# setup-keycloak.sh — Provision a Keycloak realm for the Flogo MCP OAuth 2.0 sample.
#
# Creates a realm, client scopes, a confidential client, protocol mappers
# (audience + per-user "scopes" array), client roles, and demo users with
# role assignments that mirror the Healthcare access model.
#
# Prerequisites:
#   - A running Keycloak (see README: docker run ... quay.io/keycloak/keycloak:26.6.3)
#   - curl and python3 on PATH
#
# Usage:
#   ./setup-keycloak.sh
#
# Override any of the defaults via environment variables, e.g.:
#   KC_URL=http://localhost:9098 REALM=flogo-mcp ./setup-keycloak.sh
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------
KC_URL="${KC_URL:-http://localhost:9098}"          # Keycloak base URL
ADMIN_USER="${ADMIN_USER:-admin}"                  # Keycloak admin username
ADMIN_PASS="${ADMIN_PASS:-admin}"                  # Keycloak admin password
REALM="${REALM:-flogo-mcp}"                        # Realm to create
CLIENT_ID="${CLIENT_ID:-flogo-mcp-server}"         # OAuth client id
RESOURCE_URL="${RESOURCE_URL:-http://localhost:9097/mcp}"  # MCP server resource (aud / RFC 8707)
USER_PASSWORD="${USER_PASSWORD:-Password123!}"     # Password set for all demo users

# Scopes used by the sample. "mcp:tools" is the server-level required scope
# (trigger setting oauthRequiredScopes); the rest are per-handler scopes.
SCOPES=(mcp:tools patient:read records:read patient:write token:inspect)

# Demo users -> space-separated list of roles/scopes granted to each.
# guest deliberately lacks mcp:tools to demonstrate server-level rejection.
declare -A USER_ROLES=(
  [receptionist]="mcp:tools patient:read"
  [doctor]="mcp:tools patient:read records:read"
  [admin]="mcp:tools patient:read records:read patient:write token:inspect"
  [guest]="patient:read"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
jqpy() { python3 -c "import sys,json; $1" ; }   # tiny JSON helper via python3

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" ; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*" ; }

admin_token() {
  curl -s -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" \
    -d "grant_type=password" -d "client_id=admin-cli" \
    | jqpy "print(json.load(sys.stdin)['access_token'])"
}

# api METHOD PATH [JSON_BODY]  -> performs an admin REST call, returns body
api() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -s -X "$method" "$KC_URL/admin/realms$path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -s -X "$method" "$KC_URL/admin/realms$path" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json"
  fi
}

# ---------------------------------------------------------------------------
# 0. Authenticate
# ---------------------------------------------------------------------------
log "Getting admin token from $KC_URL"
TOKEN="$(admin_token)"
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || { echo "Failed to get admin token — is Keycloak up and are the admin credentials correct?"; exit 1; }
ok "authenticated as $ADMIN_USER"

# ---------------------------------------------------------------------------
# 1. Realm
# ---------------------------------------------------------------------------
log "Creating realm '$REALM'"
if api GET "/$REALM" | grep -q '"realm"'; then
  ok "realm already exists"
else
  api POST "" "{\"realm\":\"$REALM\",\"enabled\":true}" >/dev/null
  ok "realm created"
fi

# ---------------------------------------------------------------------------
# 2. Client scopes (optional scopes carried in the standard 'scope' claim)
# ---------------------------------------------------------------------------
log "Creating client scopes"
for s in "${SCOPES[@]}"; do
  api POST "/$REALM/client-scopes" "{
    \"name\":\"$s\",\"description\":\"Scope $s\",\"protocol\":\"openid-connect\",
    \"attributes\":{\"include.in.token.scope\":\"true\",\"display.on.consent.screen\":\"true\"}}" >/dev/null || true
  ok "$s"
done

# ---------------------------------------------------------------------------
# 3. Confidential client
# ---------------------------------------------------------------------------
log "Creating client '$CLIENT_ID'"
api POST "/$REALM/clients" "{
  \"clientId\":\"$CLIENT_ID\",\"name\":\"Flogo MCP Server\",
  \"publicClient\":false,\"serviceAccountsEnabled\":true,
  \"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":true,
  \"protocol\":\"openid-connect\",\"enabled\":true,
  \"redirectUris\":[\"https://vscode.dev/redirect\",\"http://localhost:3000/callback\",\"$RESOURCE_URL/*\"],
  \"webOrigins\":[\"+\"]}" >/dev/null || true

CLIENT_UUID="$(api GET "/$REALM/clients?clientId=$CLIENT_ID" | jqpy "print(json.load(sys.stdin)[0]['id'])")"
ok "client uuid = $CLIENT_UUID"

CLIENT_SECRET="$(api GET "/$REALM/clients/$CLIENT_UUID/client-secret" | jqpy "print(json.load(sys.stdin).get('value',''))")"
ok "client secret captured"

# Attach the client scopes as optional so clients may request them.
log "Attaching client scopes (optional) to client"
for s in "${SCOPES[@]}"; do
  SCOPE_UUID="$(api GET "/$REALM/client-scopes" | jqpy "print(next((x['id'] for x in json.load(sys.stdin) if x['name']=='$s'),''))")"
  [[ -n "$SCOPE_UUID" ]] && api PUT "/$REALM/clients/$CLIENT_UUID/optional-client-scopes/$SCOPE_UUID" >/dev/null || true
done
ok "scopes attached"

# ---------------------------------------------------------------------------
# 4. Protocol mappers: audience (aud = resource URL) + per-user scopes array
# ---------------------------------------------------------------------------
log "Adding audience mapper (aud = $RESOURCE_URL)"
api POST "/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" "{
  \"name\":\"mcp-audience\",\"protocol\":\"openid-connect\",
  \"protocolMapper\":\"oidc-audience-mapper\",
  \"config\":{\"included.custom.audience\":\"$RESOURCE_URL\",
    \"id.token.claim\":\"false\",\"access.token.claim\":\"true\"}}" >/dev/null || true
ok "audience mapper"

log "Adding client-role -> 'scopes' array mapper (per-user scopes)"
api POST "/$REALM/clients/$CLIENT_UUID/protocol-mappers/models" "{
  \"name\":\"mcp-scopes-mapper\",\"protocol\":\"openid-connect\",
  \"protocolMapper\":\"oidc-usermodel-client-role-mapper\",
  \"config\":{\"claim.name\":\"scopes\",\"jsonType.label\":\"String\",\"multivalued\":\"true\",
    \"usermodel.clientRoleMapping.clientId\":\"$CLIENT_ID\",
    \"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"userinfo.token.claim\":\"true\"}}" >/dev/null || true
ok "scopes mapper"

# ---------------------------------------------------------------------------
# 5. Client roles (one per scope) — drive the per-user 'scopes' claim
# ---------------------------------------------------------------------------
log "Creating client roles"
for s in "${SCOPES[@]}"; do
  api POST "/$REALM/clients/$CLIENT_UUID/roles" "{\"name\":\"$s\",\"description\":\"Access to $s\"}" >/dev/null || true
  ok "$s"
done

# ---------------------------------------------------------------------------
# 6. Users + role assignments
# ---------------------------------------------------------------------------
log "Creating users and assigning roles"
for user in "${!USER_ROLES[@]}"; do
  api POST "/$REALM/users" "{
    \"username\":\"$user\",\"email\":\"$user@hospital.example\",\"enabled\":true,\"emailVerified\":true,
    \"firstName\":\"$user\",\"lastName\":\"Demo\",
    \"credentials\":[{\"type\":\"password\",\"value\":\"$USER_PASSWORD\",\"temporary\":false}]}" >/dev/null || true

  USER_UUID="$(api GET "/$REALM/users?username=$user&exact=true" | jqpy "print(json.load(sys.stdin)[0]['id'])")"

  # Build the role-representation array for this user's granted roles.
  ROLE_JSON="$(
    api GET "/$REALM/clients/$CLIENT_UUID/roles" | python3 -c "
import sys, json
want=set('''${USER_ROLES[$user]}'''.split())
roles=[{'id':r['id'],'name':r['name']} for r in json.load(sys.stdin) if r['name'] in want]
print(json.dumps(roles))"
  )"
  api POST "/$REALM/users/$USER_UUID/role-mappings/clients/$CLIENT_UUID" "$ROLE_JSON" >/dev/null || true
  ok "$user  [${USER_ROLES[$user]}]"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
ISSUER="$KC_URL/realms/$REALM"
cat <<EOF

============================================================================
 Keycloak setup complete.
============================================================================

Set these values as the Flogo app properties (or leave the defaults if they match):

  FlogoMcpServer.OAUTH_ISSUER     = $ISSUER
  FlogoMcpServer.OAUTH_JWKS_URL   = $ISSUER/protocol/openid-connect/certs
  FlogoMcpServer.OAUTH_AUDIENCE   = $RESOURCE_URL

Client:
  client_id     = $CLIENT_ID
  client_secret = $CLIENT_SECRET

Demo users (password: $USER_PASSWORD):
  receptionist  -> mcp:tools patient:read
  doctor        -> mcp:tools patient:read records:read
  admin         -> mcp:tools patient:read records:read patient:write token:inspect
  guest         -> patient:read              (no mcp:tools => rejected at server level)

Get a token (Resource Owner Password grant) for a user, e.g. doctor:

  curl -s -X POST "$ISSUER/protocol/openid-connect/token" \\
    -d grant_type=password \\
    -d client_id=$CLIENT_ID \\
    -d client_secret=$CLIENT_SECRET \\
    -d username=doctor -d password='$USER_PASSWORD' \\
    -d scope='openid mcp:tools patient:read records:read' | python3 -m json.tool

Decode the access_token payload to verify iss / aud / scope / scopes:

  echo "<access_token>" | python3 -c "import sys,json,base64; \\
    p=sys.stdin.read().strip().split('.')[1]; p+='='*(-len(p)%4); \\
    print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))"
============================================================================
EOF
