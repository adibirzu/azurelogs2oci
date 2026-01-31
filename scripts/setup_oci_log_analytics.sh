#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# setup_oci_log_analytics.sh – Provision OCI Streaming + Log
#   Analytics resources for the Azure → OCI log pipeline.
#
# Creates (or reuses existing):
#   1. Stream Pool + Stream (Kafka-compatible ingest)
#   2. Log Analytics Log Group (AzureLogs)
#   3. Log Analytics custom fields (Azure EntraID Audit schema)
#   4. Log Analytics JSON parser (Azure EntraID Audit JSON Parser)
#   5. Log Analytics source (Azure EntraID Audit Logs)
#   6. Service Connector Hub (Stream → Log Analytics)
#
# Prerequisites:
#   - oci CLI configured (oci setup config)
#   - .env populated with OCI variables (or prompted)
#   - Python 3 + oci-sdk (pip install oci)
#
# Usage:
#   ./scripts/setup_oci_log_analytics.sh
# ─────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_PATH="$REPO_ROOT/.env"

info() { printf "ℹ️  %s\n" "$*"; }
ok()   { printf "✅ %s\n" "$*"; }
warn() { printf "⚠️  %s\n" "$*" >&2; }
err()  { printf "❌ %s\n" "$*" >&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}

prompt_default() {
  local prompt="$1" default="$2" var
  read -r -p "$prompt [$default]: " var
  if [[ -z "$var" ]]; then echo "$default"; else echo "$var"; fi
}

prompt_required() {
  local prompt="$1" default="${2:-}" val=""
  while true; do
    read -r -p "$prompt${default:+ [$default]}: " val
    if [[ -z "$val" ]]; then
      if [[ -n "$default" ]]; then val="$default"; break; fi
      warn "This value is required."
      continue
    fi
    break
  done
  echo "$val"
}

prompt_yn() {
  local prompt="$1" default="${2:-y}" ans
  read -r -p "$prompt [$default]: " ans
  ans="${ans:-$default}"
  [[ "$ans" =~ ^[Yy] ]]
}

require_cmd oci
require_cmd python3

# Verify OCI Python SDK is installed (required for field/parser creation)
if ! python3 -c "import oci" 2>/dev/null; then
  err "OCI Python SDK not found. Install it with: pip install oci"
  exit 1
fi

# Load existing env
if [[ -f "$ENV_PATH" ]]; then
  info "Loading existing values from $ENV_PATH"
  set +u; set -a
  # shellcheck disable=SC1090
  source "$ENV_PATH"
  set +a; set -u
fi

# ── Collect required OCI parameters ──────────────────────────
OCI_COMPARTMENT_OCID="${OCI_COMPARTMENT_OCID:-}"
OCI_REGION="${region:-${OCI_REGION:-}}"
OCI_USER_OCID="${user:-${OCI_USER_OCID:-}}"
OCI_FINGERPRINT="${fingerprint:-${OCI_FINGERPRINT:-}}"
OCI_TENANCY_OCID="${tenancy:-${OCI_TENANCY_OCID:-}}"
OCI_KEY_FILE="${KEY_FILE:-${OCI_KEY_FILE:-}}"
OCI_KEY_CONTENT="${key_content:-${OCI_KEY_CONTENT:-}}"
OCI_KEY_PASSPHRASE="${pass_phrase:-${OCI_KEY_PASSPHRASE:-}}"

OCI_COMPARTMENT_OCID="$(prompt_required "OCI compartment OCID" "$OCI_COMPARTMENT_OCID")"
OCI_REGION="$(prompt_required "OCI region" "${OCI_REGION:-us-ashburn-1}")"

if [[ -z "$OCI_USER_OCID" ]]; then
  OCI_USER_OCID="$(prompt_required "OCI user OCID" "")"
fi
if [[ -z "$OCI_FINGERPRINT" ]]; then
  OCI_FINGERPRINT="$(prompt_required "OCI API key fingerprint" "")"
fi
if [[ -z "$OCI_TENANCY_OCID" ]]; then
  OCI_TENANCY_OCID="$(prompt_required "OCI tenancy OCID" "")"
fi
if [[ -z "$OCI_KEY_CONTENT" && -z "$OCI_KEY_FILE" ]]; then
  read -r -p "Path to OCI private key file (leave blank to paste): " key_path
  if [[ -n "$key_path" && -f "$key_path" ]]; then
    OCI_KEY_FILE="$key_path"
    OCI_KEY_CONTENT="$(cat "$key_path")"
  else
    read -r -s -p "Paste OCI private key content: " OCI_KEY_CONTENT
    echo
  fi
elif [[ -z "$OCI_KEY_CONTENT" && -n "$OCI_KEY_FILE" && -f "$OCI_KEY_FILE" ]]; then
  OCI_KEY_CONTENT="$(cat "$OCI_KEY_FILE")"
fi

# Defaults
STREAM_POOL_NAME="${OCI_STREAM_POOL_NAME:-MultiCloud_Log_Pool}"
STREAM_NAME="${OCI_STREAM_NAME:-azure-inbound-stream}"
PARTITIONS="${OCI_STREAM_PARTITIONS:-1}"
LOG_GROUP_NAME="${OCI_LOG_GROUP_NAME:-AzureLogs}"
NAMESPACE="${OCI_LOG_ANALYTICS_NAMESPACE:-}"
SCH_NAME="${OCI_SCH_NAME:-Azure-Stream-to-LogAnalytics}"

# Parser / source names
PARSER_NAME="azureEntraIDAuditJsonParser"
SOURCE_NAME="Azure EntraID Audit Logs"

echo ""
echo "============================================================"
echo "  OCI End-to-End Setup for azurelogs2oci"
echo "============================================================"
echo "  Compartment:  ${OCI_COMPARTMENT_OCID:0:30}..."
echo "  Region:       $OCI_REGION"
echo "  Stream Pool:  $STREAM_POOL_NAME"
echo "  Stream:       $STREAM_NAME"
echo "  Log Group:    $LOG_GROUP_NAME"
echo "  SCH:          $SCH_NAME"
echo "  Parser:       $PARSER_NAME"
echo "  Source:       $SOURCE_NAME"
echo "============================================================"
echo ""

# ── Auto-detect Log Analytics namespace ──────────────────────
if [[ -z "$NAMESPACE" ]]; then
  info "Detecting Log Analytics namespace..."
  NAMESPACE=$(oci log-analytics namespace list \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --query 'data.items[0]."namespace-name"' --raw-output 2>/dev/null || true)
  if [[ -z "$NAMESPACE" || "$NAMESPACE" == "null" ]]; then
    err "Could not detect Log Analytics namespace."
    err "Ensure Log Analytics is onboarded in your tenancy:"
    err "  OCI Console > Observability & Management > Log Analytics > 'Start Using Log Analytics'"
    err "Or set OCI_LOG_ANALYTICS_NAMESPACE explicitly."
    exit 1
  fi
  ok "Namespace: $NAMESPACE"
fi

# ── 1. Stream Pool ───────────────────────────────────────────
echo ""
echo "1/7  Stream Pool: $STREAM_POOL_NAME"
EXISTING_POOL=$(oci streaming admin stream-pool list \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --name "$STREAM_POOL_NAME" \
    --lifecycle-state ACTIVE \
    --query 'data[0].id' --raw-output 2>/dev/null || true)

if [[ -n "$EXISTING_POOL" && "$EXISTING_POOL" != "null" ]]; then
  POOL_ID="$EXISTING_POOL"
  ok "Pool already exists: ${POOL_ID:0:50}..."
  if prompt_yn "     Use existing pool? (y=reuse, n=create new)" "y"; then
    : # keep POOL_ID
  else
    STREAM_POOL_NAME="$(prompt_required "New stream pool name" "MultiCloud_Log_Pool_Azure")"
    POOL_ID=$(oci streaming admin stream-pool create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --name "$STREAM_POOL_NAME" \
        --query 'data.id' --raw-output \
        --wait-for-state ACTIVE \
        --max-wait-seconds 120)
    ok "Pool created: ${POOL_ID:0:50}..."
  fi
else
  POOL_ID=$(oci streaming admin stream-pool create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --name "$STREAM_POOL_NAME" \
      --query 'data.id' --raw-output \
      --wait-for-state ACTIVE \
      --max-wait-seconds 120)
  ok "Pool created: ${POOL_ID:0:50}..."
fi

# ── 2. Stream ────────────────────────────────────────────────
echo "2/7  Stream: $STREAM_NAME"

# Check if we already have a stream OCID from .env
EXISTING_STREAM_OCID="${StreamOcid:-${OCI_STREAM_OCID:-}}"
if [[ -n "$EXISTING_STREAM_OCID" && "$EXISTING_STREAM_OCID" != "null" ]]; then
  ok "Stream OCID from .env: ${EXISTING_STREAM_OCID:0:50}..."
  if prompt_yn "     Use existing stream? (y=reuse, n=create new)" "y"; then
    STREAM_ID="$EXISTING_STREAM_OCID"
  else
    STREAM_NAME="$(prompt_default "New stream name" "$STREAM_NAME")"
    STREAM_ID=$(oci streaming admin stream create \
        --name "$STREAM_NAME" \
        --partitions "$PARTITIONS" \
        --stream-pool-id "$POOL_ID" \
        --query 'data.id' --raw-output \
        --wait-for-state ACTIVE \
        --max-wait-seconds 120)
    ok "Stream created: ${STREAM_ID:0:50}..."
  fi
else
  EXISTING_STREAM=$(oci streaming admin stream list \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --name "$STREAM_NAME" \
      --lifecycle-state ACTIVE \
      --query 'data[0].id' --raw-output 2>/dev/null || true)

  if [[ -n "$EXISTING_STREAM" && "$EXISTING_STREAM" != "null" ]]; then
    STREAM_ID="$EXISTING_STREAM"
    ok "Stream already exists: ${STREAM_ID:0:50}..."
    if prompt_yn "     Use existing stream? (y=reuse, n=create new)" "y"; then
      : # keep
    else
      STREAM_NAME="$(prompt_default "New stream name" "azure-inbound-stream-2")"
      STREAM_ID=$(oci streaming admin stream create \
          --name "$STREAM_NAME" \
          --partitions "$PARTITIONS" \
          --stream-pool-id "$POOL_ID" \
          --query 'data.id' --raw-output \
          --wait-for-state ACTIVE \
          --max-wait-seconds 120)
      ok "Stream created: ${STREAM_ID:0:50}..."
    fi
  else
    STREAM_ID=$(oci streaming admin stream create \
        --name "$STREAM_NAME" \
        --partitions "$PARTITIONS" \
        --stream-pool-id "$POOL_ID" \
        --query 'data.id' --raw-output \
        --wait-for-state ACTIVE \
        --max-wait-seconds 120)
    ok "Stream created: ${STREAM_ID:0:50}..."
  fi
fi

# ── 3. Kafka Connection Info ─────────────────────────────────
echo "3/7  Retrieving Kafka connection details..."
POOL_INFO=$(oci streaming admin stream-pool get --stream-pool-id "$POOL_ID")
KAFKA_ENDPOINT=$(echo "$POOL_INFO" | python3 -c "
import sys, json
d = json.load(sys.stdin)
settings = d.get('data', {}).get('kafka-settings', {})
print(settings.get('bootstrap-servers', 'N/A'))
" 2>/dev/null || echo "N/A")
ok "Bootstrap servers: $KAFKA_ENDPOINT"

# ── 4. Log Analytics Log Group ───────────────────────────────
echo "4/7  Log Analytics Log Group: $LOG_GROUP_NAME"
EXISTING_LG=$(oci log-analytics log-group list \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --namespace-name "$NAMESPACE" \
    --query "data.items[?\"display-name\"=='$LOG_GROUP_NAME'].id | [0]" \
    --raw-output 2>/dev/null || true)

if [[ -n "$EXISTING_LG" && "$EXISTING_LG" != "null" && "$EXISTING_LG" != "None" ]]; then
  LOG_GROUP_ID="$EXISTING_LG"
  ok "Log Group already exists: ${LOG_GROUP_ID:0:50}..."
  if prompt_yn "     Use existing log group? (y=reuse, n=create new)" "y"; then
    : # keep
  else
    LOG_GROUP_NAME="$(prompt_required "New log group name" "AzureLogs-2")"
    LOG_GROUP_ID=$(oci log-analytics log-group create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --namespace-name "$NAMESPACE" \
        --display-name "$LOG_GROUP_NAME" \
        --description "Azure EntraID Audit log imports via azurelogs2oci pipeline" \
        --query 'data.id' --raw-output)
    ok "Log Group created: ${LOG_GROUP_ID:0:50}..."
  fi
else
  LOG_GROUP_ID=$(oci log-analytics log-group create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --namespace-name "$NAMESPACE" \
      --display-name "$LOG_GROUP_NAME" \
      --description "Azure EntraID Audit log imports via azurelogs2oci pipeline" \
      --query 'data.id' --raw-output)
  ok "Log Group created: ${LOG_GROUP_ID:0:50}..."
fi

# ── 5. Create custom Log Analytics fields + parser ───────────
echo "5/7  Creating Azure EntraID parser and fields..."
export LA_NAMESPACE="$NAMESPACE"
export LA_USER="$OCI_USER_OCID"
export LA_FINGERPRINT="$OCI_FINGERPRINT"
export LA_TENANCY="$OCI_TENANCY_OCID"
export LA_REGION="$OCI_REGION"
export LA_KEY_CONTENT="$OCI_KEY_CONTENT"
export LA_KEY_FILE="${OCI_KEY_FILE:-}"
export LA_PASSPHRASE="${OCI_KEY_PASSPHRASE:-}"

python3 << 'PYEOF'
import oci, os, sys, json, re, textwrap

# Build OCI config
key_file = os.environ.get("LA_KEY_FILE")
key_content = os.environ.get("LA_KEY_CONTENT", "")

if key_file and os.path.isfile(os.path.expanduser(key_file)):
    with open(os.path.expanduser(key_file)) as f:
        raw = f.read()
    begin = re.search(r"-----BEGIN [A-Z ]+-----", raw)
    end = re.search(r"-----END [A-Z ]+-----", raw)
    key_pem = raw[begin.start():end.end()] if begin and end else raw
elif key_content:
    # Normalize escaped newlines
    normalized = key_content.replace("\\n", "\n").strip()
    begin = re.search(r"-----BEGIN [A-Z ]+-----", normalized)
    end = re.search(r"-----END [A-Z ]+-----", normalized)
    if begin and end:
        begin_line = begin.group()
        end_line = end.group()
        body = normalized[begin.end():end.start()]
        # Handle encrypted key headers
        encr = ""
        proc = re.search(r"Proc-Type: [^\n]+", body)
        dek = re.search(r"DEK-Info: [^\n]+", body)
        if proc:
            encr += proc.group().strip() + "\n"
            body = body.replace(proc.group(), "")
        if dek:
            encr += dek.group().strip() + "\n"
            body = body.replace(dek.group(), "")
        compact = re.sub(r"\s+", "", body)
        wrapped = "\n".join(textwrap.wrap(compact, 64))
        parts = [begin_line]
        if encr:
            parts.append(encr.rstrip("\n"))
        parts.append(wrapped)
        parts.append(end_line)
        key_pem = "\n".join(parts)
    else:
        key_pem = normalized
else:
    print("ERROR: No OCI key content or file provided")
    sys.exit(1)

cfg = {
    "user": os.environ["LA_USER"],
    "key_content": key_pem,
    "pass_phrase": os.environ.get("LA_PASSPHRASE", ""),
    "fingerprint": os.environ["LA_FINGERPRINT"],
    "tenancy": os.environ["LA_TENANCY"],
    "region": os.environ["LA_REGION"],
}

namespace = os.environ["LA_NAMESPACE"]
client = oci.log_analytics.LogAnalyticsClient(cfg)

# ── Create custom fields ──────────────────────────────────────
from oci.log_analytics.models import UpsertLogAnalyticsFieldDetails

field_display_names = [
    # Multicloud (shared across all cloud providers)
    "Cloud Provider",
    # Core Azure EntraID Audit fields
    "Azure Time Generated",
    "Azure Event ID",
    "Azure Operation",
    "Azure Record Type",
    "Azure Result Status",
    "Azure User Type",
    "Azure User ID",
    "Azure User Key",
    "Azure Workload",
    "Azure Object ID",
    "Azure Client IP",
    "Azure Organization ID",
    "Azure Schema Version",
    "Azure Creation Time",
    "Azure AD Event Type",
    # Actor / Target context
    "Azure Actor Context ID",
    "Azure Actor IP Address",
    "Azure Inter Systems ID",
    "Azure Intra System ID",
    "Azure Target Context ID",
    "Azure Application ID",
]

field_name_map = {}
for display_name in field_display_names:
    details = UpsertLogAnalyticsFieldDetails()
    details.display_name = display_name
    details.data_type = "String"
    details.is_multi_valued = False
    try:
        resp = client.upsert_field(namespace, details)
        field_name_map[display_name] = resp.data.name
        print(f"     Field OK  {resp.data.name:30s} -> {display_name}")
    except oci.exceptions.ServiceError:
        # Field may already exist; try to find it
        try:
            fields = client.list_fields(namespace, display_name_contains=display_name).data.items
            for f in fields:
                if f.display_name == display_name:
                    field_name_map[display_name] = f.name
                    print(f"     Field EXISTS {f.name:27s} -> {display_name}")
                    break
        except Exception as ex:
            print(f"     Field ERR: {display_name}: {ex}")

# ── Create JSON parser ────────────────────────────────────────
# Map: (field_display_name or built-in name, json_path, seq)
# 26 field mappings covering Azure EntraID Audit log schema
field_mappings = [
    # Built-in LA fields
    ("msg",                       "$.Operation",                           1),
    ("sevlvl",                    "$.ResultStatus",                        2),
    ("time",                      "$.TimeGenerated",                       3),
    ("method",                    "$.Operation",                           4),
    # Multicloud
    ("Cloud Provider",            "$.cloudProvider",                       5),
    # Core Azure EntraID Audit
    ("Azure Time Generated",      "$.TimeGenerated",                       6),
    ("Azure Event ID",            "$.Id",                                  7),
    ("Azure Operation",           "$.Operation",                           8),
    ("Azure Record Type",         "$.RecordType",                          9),
    ("Azure Result Status",       "$.ResultStatus",                       10),
    ("Azure User Type",           "$.UserType",                           11),
    ("Azure User ID",             "$.UserId",                             12),
    ("Azure User Key",            "$.UserKey",                            13),
    ("Azure Workload",            "$.Workload",                           14),
    ("Azure Object ID",           "$.ObjectId",                           15),
    ("Azure Client IP",           "$.ClientIP",                           16),
    ("Azure Organization ID",     "$.OrganizationId",                     17),
    ("Azure Schema Version",      "$.Version",                            18),
    ("Azure Creation Time",       "$.CreationTime",                       19),
    ("Azure AD Event Type",       "$.AzureActiveDirectoryEventType",      20),
    # Actor / Target context
    ("Azure Actor Context ID",    "$.ActorContextId",                     21),
    ("Azure Actor IP Address",    "$.ActorIpAddress",                     22),
    ("Azure Inter Systems ID",    "$.InterSystemsId",                     23),
    ("Azure Intra System ID",     "$.IntraSystemId",                      24),
    ("Azure Target Context ID",   "$.TargetContextId",                    25),
    ("Azure Application ID",      "$.ApplicationId",                      26),
]

from oci.log_analytics.models import (
    UpsertLogAnalyticsParserDetails,
    LogAnalyticsParserField,
    LogAnalyticsField,
)

parser_field_maps = []
for name_or_display, json_path, seq in field_mappings:
    internal = field_name_map.get(name_or_display, name_or_display)
    parser_field_maps.append(
        LogAnalyticsParserField(
            field=LogAnalyticsField(name=internal),
            parser_field_name=internal,
            parser_field_sequence=seq,
            storage_field_name=internal,
            structured_column_info=json_path,
        )
    )

# Example log content for UI validation (synthetic EntraID Audit log)
example_log = {
    "cloudProvider": "Azure",
    "TimeGenerated": "2026-01-15T10:30:00.000000+00:00",
    "Id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "Operation": "Add member to group",
    "RecordType": 11,
    "ResultStatus": "Success",
    "UserType": "Admin",
    "UserId": "admin@example.com",
    "UserKey": "11bfead6-20de-405e-a265-e75dfbb48a65",
    "Workload": "AzureActiveDirectory",
    "ObjectId": "19c66d27-6602-43b5-ac0e-5eb87b9f6c8d",
    "ClientIP": "203.0.113.50",
    "OrganizationId": "7c38a3a9-2710-4798-83e6-82f14ba656bd",
    "Version": 1,
    "CreationTime": "2026-01-15T10:30:00",
    "AzureActiveDirectoryEventType": 2,
    "ExtendedProperties": [
        {"Name": "UserAgent", "Value": "Mozilla/5.0"},
        {"Name": "RequestType", "Value": "OAuth2:Token"}
    ],
    "Actor": [
        {"ID": "91af402b-5540-4d3d-9029-ff26768def1e", "Type": 0},
        {"ID": "admin@example.com", "Type": 5}
    ],
    "ActorContextId": "3cd6474d-ca79-445c-a336-7e21738e935f",
    "ActorIpAddress": "203.0.113.50",
    "InterSystemsId": "2632722a-4354-471b-8356-08d44451f803",
    "IntraSystemId": "ec6869c2-b550-492c-a5f3-b29ee1bd1f43",
    "Target": [
        {"ID": "aea77556-60a8-479f-8afc-3c6ecfddbf1f", "Type": 0}
    ],
    "TargetContextId": "b4c245f3-521b-456d-9eb1-ca5a86d28394",
    "ApplicationId": "00000002-0000-0ff1-ce00-000000000000",
}
example_content = json.dumps(example_log, indent=2)

# Upsert parser via SDK (handles etag for updates)
parser_details = UpsertLogAnalyticsParserDetails(
    name="azureEntraIDAuditJsonParser",
    display_name="Azure EntraID Audit JSON Parser",
    description="Parses Azure EntraID Audit logs with 26 field mappings covering identity, operations, actors, and metadata fields. Supports multicloud monitoring with Cloud Provider = Azure.",
    type="JSON",
    language="en_US",
    encoding="UTF-8",
    is_default=True,
    is_single_line_content=False,
    is_system=False,
    header_content="$:0",
    content=example_content,
    example_content=example_content,
    field_maps=parser_field_maps,
)

# Get existing etag if parser already exists
etag = None
try:
    existing = client.get_parser(namespace, "azureEntraIDAuditJsonParser")
    etag = existing.headers.get("etag")
except oci.exceptions.ServiceError:
    pass

kwargs = {"if_match": etag} if etag else {}
result = client.upsert_parser(namespace, parser_details, **kwargs)
print(f"     Parser OK: {result.data.name} ({len(result.data.field_maps)} field maps)")

# Save field name map for source creation
with open('/tmp/azure_field_name_map.json', 'w') as f:
    json.dump(field_name_map, f, indent=2)

PYEOF

# ── 6. Create Log Analytics source ───────────────────────────
echo "6/7  Creating Log Analytics source: $SOURCE_NAME"

EXISTING_SOURCE=$(oci log-analytics source list-sources \
    --namespace-name "$NAMESPACE" \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --name "$SOURCE_NAME" \
    --is-system ALL \
    --query 'data.items[0].name' --raw-output 2>/dev/null || true)

if [[ -n "$EXISTING_SOURCE" && "$EXISTING_SOURCE" != "null" && "$EXISTING_SOURCE" != "None" ]]; then
  ok "Source already exists: $EXISTING_SOURCE"
else
  # Prepare parsers and entity-types JSON
  cat > /tmp/azure_source_parsers.json << 'JSONEOF'
[{"name": "azureEntraIDAuditJsonParser", "isDefault": true}]
JSONEOF

  cat > /tmp/azure_source_entity_types.json << 'JSONEOF'
[{"entityType": "oci_generic_resource", "entityTypeCategory": "Undefined", "entityTypeDisplayName": "OCI Generic Resource"}]
JSONEOF

  SOURCE_RESULT=$(oci log-analytics source upsert-source \
      --namespace-name "$NAMESPACE" \
      --name azureEntraIDAuditSource \
      --display-name "$SOURCE_NAME" \
      --description "Azure EntraID Audit structured logs from Event Hub via OCI Streaming. Supports multicloud monitoring with Cloud Provider = Azure." \
      --type-name "os_file" \
      --is-system false \
      --is-for-cloud false \
      --parsers file:///tmp/azure_source_parsers.json \
      --entity-types file:///tmp/azure_source_entity_types.json \
      2>&1 || true)

  if echo "$SOURCE_RESULT" | grep -q '"name"'; then
    ok "Source created"
  else
    warn "Source creation result: $(echo "$SOURCE_RESULT" | head -3)"
  fi
fi

# ── 7. Create Service Connector Hub ──────────────────────────
echo "7/7  Creating Service Connector Hub: $SCH_NAME"

EXISTING_SCH=$(oci sch service-connector list \
    --compartment-id "$OCI_COMPARTMENT_OCID" \
    --display-name "$SCH_NAME" \
    --lifecycle-state ACTIVE \
    --query 'data.items[0].id' --raw-output 2>/dev/null || true)

if [[ -n "$EXISTING_SCH" && "$EXISTING_SCH" != "null" && "$EXISTING_SCH" != "None" ]]; then
  SCH_ID="$EXISTING_SCH"
  ok "SCH already exists: ${SCH_ID:0:50}..."
  if prompt_yn "     Use existing SCH? (y=reuse, n=create new)" "y"; then
    : # keep
  else
    SCH_NAME="$(prompt_required "New SCH name" "Azure-Stream-to-LogAnalytics-2")"
    # Source: OCI Streaming
    cat > /tmp/azure_sch_source.json << JSONEOF
{
  "kind": "streaming",
  "streamId": "$STREAM_ID",
  "cursor": {"kind": "TRIM_HORIZON"}
}
JSONEOF
    # Target: Log Analytics
    cat > /tmp/azure_sch_target.json << JSONEOF
{
  "kind": "loggingAnalytics",
  "logGroupId": "$LOG_GROUP_ID",
  "logSourceIdentifier": "$SOURCE_NAME"
}
JSONEOF

    SCH_ID=$(oci sch service-connector create \
        --compartment-id "$OCI_COMPARTMENT_OCID" \
        --display-name "$SCH_NAME" \
        --description "Forwards Azure EntraID Audit logs from OCI Streaming to Log Analytics ($LOG_GROUP_NAME group) using Azure EntraID parser" \
        --source file:///tmp/azure_sch_source.json \
        --target file:///tmp/azure_sch_target.json \
        --query 'data.id' --raw-output \
        --wait-for-state ACTIVE \
        --max-wait-seconds 300 2>&1 || true)

    if [[ -n "$SCH_ID" && "$SCH_ID" != "null" ]]; then
      ok "SCH created: ${SCH_ID:0:50}..."
    else
      warn "SCH creation may need manual setup (check IAM policies)"
    fi
  fi
else
  # Source: OCI Streaming
  cat > /tmp/azure_sch_source.json << JSONEOF
{
  "kind": "streaming",
  "streamId": "$STREAM_ID",
  "cursor": {"kind": "TRIM_HORIZON"}
}
JSONEOF
  # Target: Log Analytics
  cat > /tmp/azure_sch_target.json << JSONEOF
{
  "kind": "loggingAnalytics",
  "logGroupId": "$LOG_GROUP_ID",
  "logSourceIdentifier": "$SOURCE_NAME"
}
JSONEOF

  SCH_ID=$(oci sch service-connector create \
      --compartment-id "$OCI_COMPARTMENT_OCID" \
      --display-name "$SCH_NAME" \
      --description "Forwards Azure EntraID Audit logs from OCI Streaming to Log Analytics ($LOG_GROUP_NAME group) using Azure EntraID parser" \
      --source file:///tmp/azure_sch_source.json \
      --target file:///tmp/azure_sch_target.json \
      --query 'data.id' --raw-output \
      --wait-for-state ACTIVE \
      --max-wait-seconds 300 2>&1 || true)

  if [[ -n "$SCH_ID" && "$SCH_ID" != "null" ]]; then
    ok "SCH created: ${SCH_ID:0:50}..."
  else
    warn "SCH creation may need manual setup (check IAM policies)"
    info "Required policy: Allow any-user to {STREAM_READ, STREAM_CONSUME} in compartment <name>"
    info "                 Allow any-user to use loganalytics-log-group in compartment <name>"
  fi
fi

# ── Cleanup temp files ────────────────────────────────────────
rm -f /tmp/azure_field_name_map.json \
      /tmp/azure_source_parsers.json /tmp/azure_source_entity_types.json \
      /tmp/azure_sch_source.json /tmp/azure_sch_target.json 2>/dev/null

# ── Derive message endpoint from Kafka bootstrap ─────────────
MSG_ENDPOINT=""
if [[ "$KAFKA_ENDPOINT" != "N/A" ]]; then
  MSG_ENDPOINT="https://$(echo "$KAFKA_ENDPOINT" | cut -d: -f1)"
fi

echo ""
echo "============================================================"
echo "  OCI Log Analytics Setup Complete"
echo "============================================================"
echo ""
echo "Update .env with:"
echo "  OCI_STREAM_OCID=$STREAM_ID"
echo "  OCI_STREAM_POOL_ID=$POOL_ID"
if [[ -n "$MSG_ENDPOINT" ]]; then
  echo "  OCI_MESSAGE_ENDPOINT=$MSG_ENDPOINT"
fi
echo "  OCI_LOG_ANALYTICS_NAMESPACE=$NAMESPACE"
echo "  OCI_COMPARTMENT_OCID=$OCI_COMPARTMENT_OCID"
echo "  OCI_LOG_GROUP_NAME=$LOG_GROUP_NAME"
echo "  OCI_SCH_NAME=$SCH_NAME"
echo ""
echo "Pipeline:"
echo "  Azure Event Hub (EntraID Audit Logs)"
echo "    → Azure Function (Event Hub trigger + Cloud Provider enrichment)"
echo "    → OCI Stream: $STREAM_NAME"
echo "    → SCH: $SCH_NAME"
echo "    → Log Analytics: $LOG_GROUP_NAME (source: $SOURCE_NAME)"
echo ""
echo "Query example:"
echo "  'Cloud Provider' = 'Azure' | stats count by 'Azure Operation'"
echo ""
echo "Next steps:"
echo "  1. Update .env with the values above"
echo "  2. Run: ./scripts/drain_eventhub_to_oci.sh --from-beginning"
echo "  3. Verify in OCI Log Analytics Log Explorer"
echo ""
