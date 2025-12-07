#!/usr/bin/env bash
# Provision Azure resources (RG, storage, Function App) and deploy azurelogs2oci for continuous delivery to OCI Streaming.
# - Loads .env if present and prompts for any missing values.
# - Discovers Event Hubs and connection string via Azure CLI when possible.
# - Packages the function and deploys via zip to the Function App.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_PATH="$REPO_ROOT/.env"
FUNCTION_PATH="$REPO_ROOT/function/EventHubsNamespaceToOCIStreaming"

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
  if [[ -z "$var" ]]; then
    echo "$default"
  else
    echo "$var"
  fi
}

prompt_required() {
  local prompt="$1" default="${2:-}"
  local val=""
  while true; do
    read -r -p "$prompt${default:+ [$default]}: " val
    if [[ -z "$val" ]]; then
      if [[ -n "$default" ]]; then
        val="$default"
        break
      fi
      warn "This value is required."
      continue
    fi
    break
  done
  echo "$val"
}

prompt_secret() {
  local prompt="$1" var
  read -r -s -p "$prompt: " var
  echo
  echo "$var"
}

require_cmd az
require_cmd python3
require_cmd zip

# Load existing env without failing on unset
if [[ -f "$ENV_PATH" ]]; then
  info "Loading existing values from $ENV_PATH"
  set +u
  set -a
  # shellcheck disable=SC1090
  source "$ENV_PATH"
  set +a
  set -u
fi

# Inputs with defaults
RG_DEFAULT="${AZ_RG:-${RESOURCE_GROUP:-azurelogs2oci-rg}}"
LOC_DEFAULT="${AZ_LOCATION:-${LOCATION:-westeurope}}"
SA_DEFAULT="${AZ_STORAGE_ACCOUNT:-}"
APP_DEFAULT="${AZ_FUNCTION_APP:-}"
PLAN_TYPE_DEFAULT="${PLAN_TYPE:-consumption}" # consumption | premium

EVENTHUB_RG="${EVENTHUB_RG:-$RG_DEFAULT}"
EVENTHUB_NAMESPACE="${EVENTHUB_NAMESPACE:-}"
EVENTHUB_CONSUMER_GROUP="${EventHubConsumerGroup:-${EVENTHUB_CONSUMER_GROUP:-\$Default}}"
EVENTHUB_NAMES_CSV="${EventHubNamesCsv:-${EVENTHUB_NAME:-}}"

MessageEndpoint="${MessageEndpoint:-${OCI_MESSAGE_ENDPOINT:-}}"
StreamOcid="${StreamOcid:-${OCI_STREAM_OCID:-}}"
user="${user:-}"
key_content="${key_content:-}"
pass_phrase="${pass_phrase:-}"
fingerprint="${fingerprint:-}"
tenancy="${tenancy:-}"
region="${region:-us-ashburn-1}"

AZ_RG="$(prompt_required "Azure resource group" "${EVENTHUB_RG:-$RG_DEFAULT}")"
AZ_LOCATION="$(prompt_required "Azure location" "$LOC_DEFAULT")"
EVENTHUB_NAMESPACE="$(prompt_required "Event Hubs namespace" "${EVENTHUB_NAMESPACE:-<namespace>}")"
PLAN_TYPE="$(prompt_required "Function plan type (consumption/premium)" "$PLAN_TYPE_DEFAULT")"

# Ensure resource group exists before any downstream Azure operations
info "Ensuring resource group exists..."
az group create -n "$AZ_RG" -l "$AZ_LOCATION" >/dev/null

info "Fetching Event Hubs in namespace '$EVENTHUB_NAMESPACE'..."
HUBS=()
set +e
while IFS= read -r line; do
  [[ -n "$line" ]] && HUBS+=("$line")
done < <(az eventhubs eventhub list --resource-group "$AZ_RG" --namespace-name "$EVENTHUB_NAMESPACE" --query "[].name" -o tsv 2>/dev/null)
set -e

if [[ ${#HUBS[@]} -gt 0 ]]; then
  info "Available Event Hubs:"
  i=1
  for h in "${HUBS[@]}"; do
    echo "  [$i] $h"
    ((i++))
  done
  read -r -p "Enter comma-separated numbers or names to include (leave blank to keep current '${EVENTHUB_NAMES_CSV:-<none>}'): " selection
  if [[ -n "$selection" ]]; then
    IFS=',' read -r -a choices <<<"$selection"
    SELECTED=()
    for c in "${choices[@]}"; do
      c_trim="${c//[[:space:]]/}"
      if [[ "$c_trim" =~ ^[0-9]+$ ]]; then
        idx=$((c_trim-1))
        [[ $idx -ge 0 && $idx -lt ${#HUBS[@]} ]] && SELECTED+=("${HUBS[$idx]}")
      elif [[ -n "$c_trim" ]]; then
        SELECTED+=("$c_trim")
      fi
    done
    if [[ ${#SELECTED[@]} -gt 0 ]]; then
      EVENTHUB_NAMES_CSV="$(IFS=','; echo "${SELECTED[*]}")"
    fi
  fi
fi

EVENTHUB_NAMES_CSV="$(prompt_required "Comma-separated Event Hub names" "${EVENTHUB_NAMES_CSV:-insights-activity-logs}")"
EVENTHUB_CONSUMER_GROUP="$(prompt_required "Consumer group for function (leave \$Default if unsure)" "$EVENTHUB_CONSUMER_GROUP")"
PRIMARY_EVENTHUB="$(echo "$EVENTHUB_NAMES_CSV" | cut -d',' -f1 | tr -d '[:space:]')"

# Ensure Event Hub namespace and hubs exist (creates if missing)
info "Ensuring Event Hubs namespace exists..."
if ! az eventhubs namespace show --resource-group "$AZ_RG" --name "$EVENTHUB_NAMESPACE" >/dev/null 2>&1; then
  az eventhubs namespace create --resource-group "$AZ_RG" --name "$EVENTHUB_NAMESPACE" --location "$AZ_LOCATION" >/dev/null
  ok "Created Event Hubs namespace $EVENTHUB_NAMESPACE"
else
  ok "Namespace $EVENTHUB_NAMESPACE exists"
fi

IFS=',' read -r -a HUB_LIST <<<"$EVENTHUB_NAMES_CSV"
for hub in "${HUB_LIST[@]}"; do
  hub_trim="${hub//[[:space:]]/}"
  [[ -z "$hub_trim" ]] && continue
  if ! az eventhubs eventhub show --resource-group "$AZ_RG" --namespace-name "$EVENTHUB_NAMESPACE" --name "$hub_trim" >/dev/null 2>&1; then
    az eventhubs eventhub create --resource-group "$AZ_RG" --namespace-name "$EVENTHUB_NAMESPACE" --name "$hub_trim" >/dev/null
    ok "Created Event Hub $hub_trim"
  else
    ok "Event Hub $hub_trim exists"
  fi
  if [[ "$EVENTHUB_CONSUMER_GROUP" != "\$Default" ]]; then
    if ! az eventhubs eventhub consumer-group show --resource-group "$AZ_RG" --namespace-name "$EVENTHUB_NAMESPACE" --eventhub-name "$hub_trim" --name "$EVENTHUB_CONSUMER_GROUP" >/dev/null 2>&1; then
      az eventhubs eventhub consumer-group create --resource-group "$AZ_RG" --namespace-name "$EVENTHUB_NAMESPACE" --eventhub-name "$hub_trim" --name "$EVENTHUB_CONSUMER_GROUP" >/dev/null
      ok "Created consumer group $EVENTHUB_CONSUMER_GROUP on $hub_trim"
    fi
  fi
done

# Resolve connection string with retries
info "Resolving Event Hubs connection string from Azure..."
EventHubsConnectionString=""
for attempt in 1 2 3; do
  set +e
  EventHubsConnectionString="$(az eventhubs namespace authorization-rule keys list \
    --resource-group "$AZ_RG" \
    --namespace-name "$EVENTHUB_NAMESPACE" \
    --name "RootManageSharedAccessKey" \
    --query primaryConnectionString -o tsv 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -eq 0 && -n "$EventHubsConnectionString" ]] && break
  warn "Attempt $attempt to resolve connection string failed. Retrying in 5s..."
  sleep 5
done

if [[ -z "$EventHubsConnectionString" ]]; then
  warn "Could not auto-resolve connection string."
  EventHubsConnectionString="$(prompt_required "EventHubsConnectionString" "${EventHubsConnectionString:-Endpoint=sb://...}")"
else
  ok "Resolved connection string"
fi

# OCI inputs
MessageEndpoint="$(prompt_required "OCI message endpoint" "${MessageEndpoint:-https://cell-1.streaming.<region>.oci.oraclecloud.com}")"
StreamOcid="$(prompt_required "OCI stream OCID (not stream pool)" "${StreamOcid:-ocid1.stream.oc1..xxxx}")"
user="$(prompt_required "OCI user OCID" "${user:-ocid1.user.oc1..example}")"
fingerprint="$(prompt_required "OCI API key fingerprint" "${fingerprint:-<fingerprint>}")"
tenancy="$(prompt_required "OCI tenancy OCID" "${tenancy:-ocid1.tenancy.oc1..example}")"
region="$(prompt_required "OCI region" "$region")"

if [[ -z "$key_content" || "$key_content" == "-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----" ]]; then
  read -r -p "Path to OCI private key file (leave blank to paste): " key_path
  if [[ -z "$key_path" && -n "${KEY_FILE:-}" && -f "${KEY_FILE:-}" ]]; then
    key_path="$KEY_FILE"
  fi
  if [[ -n "$key_path" && -f "$key_path" ]]; then
    KEY_FILE="$key_path"
    key_content="$(cat "$key_path")"
  else
    key_content="$(prompt_secret "Paste OCI private key content (will be stored in Function App settings)")"
  fi
fi
# Normalize key_content (strip CR and trailing spaces)
key_content="$(printf '%s' "$key_content" | tr -d '\r')"
pass_phrase="$(prompt_default "OCI key pass phrase (blank if none)" "${pass_phrase:-}")"

# Azure names
if [[ -z "${SA_DEFAULT}" ]]; then
  RAND=$(python3 - <<'PY'
import random,string
print('logs' + ''.join(random.choices(string.ascii_lowercase + string.digits, k=8)))
PY
)
  AZ_STORAGE_ACCOUNT="$RAND"
else
  AZ_STORAGE_ACCOUNT="$SA_DEFAULT"
fi
if [[ -z "${APP_DEFAULT}" ]]; then
  RAND_APP=$(python3 - <<'PY'
import random,string
print('azurelogs2oci-' + ''.join(random.choices(string.ascii_lowercase + string.digits, k=6)))
PY
)
  AZ_FUNCTION_APP="$RAND_APP"
else
  AZ_FUNCTION_APP="$APP_DEFAULT"
fi
AZ_PLAN="${AZ_FUNCTION_APP}-plan"

AZ_STORAGE_ACCOUNT="$(prompt_default "Azure storage account name (must be globally unique)" "$AZ_STORAGE_ACCOUNT")"
AZ_FUNCTION_APP="$(prompt_default "Azure Function App name" "$AZ_FUNCTION_APP")"
AZ_PLAN="$(prompt_default "Azure App Service plan name (used for premium)" "$AZ_PLAN")"

info "Creating resource group (if needed)..."
az group create -n "$AZ_RG" -l "$AZ_LOCATION" >/dev/null

info "Creating storage account (if needed)..."
az storage account create -g "$AZ_RG" -n "$AZ_STORAGE_ACCOUNT" -l "$AZ_LOCATION" --sku Standard_LRS >/dev/null

info "Creating Function App (if needed)..."
if ! az functionapp show -g "$AZ_RG" -n "$AZ_FUNCTION_APP" >/dev/null 2>&1; then
  if [[ "$PLAN_TYPE" == "premium" ]]; then
    info "Creating premium plan $AZ_PLAN (EP1)..."
    az functionapp plan create \
      -g "$AZ_RG" \
      -n "$AZ_PLAN" \
      --location "$AZ_LOCATION" \
      --number-of-workers 1 \
      --sku EP1 \
      --is-linux >/dev/null
    az functionapp create \
      -g "$AZ_RG" \
      -n "$AZ_FUNCTION_APP" \
      --plan "$AZ_PLAN" \
      --runtime python \
      --runtime-version 3.11 \
      --functions-version 4 \
      --os-type linux \
      --storage-account "$AZ_STORAGE_ACCOUNT" >/dev/null
  else
    az functionapp create \
      -g "$AZ_RG" \
      -n "$AZ_FUNCTION_APP" \
      --consumption-plan-location "$AZ_LOCATION" \
      --runtime python \
      --runtime-version 3.11 \
      --functions-version 4 \
      --os-type linux \
      --storage-account "$AZ_STORAGE_ACCOUNT" >/dev/null
  fi
else
  warn "Function App $AZ_FUNCTION_APP already exists; will reuse."
fi

# Flatten key_content to single line for app settings
KEY_ONELINE="$(printf '%s' "$key_content" | tr -d '\r' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

info "Configuring app settings..."
az functionapp config appsettings set -g "$AZ_RG" -n "$AZ_FUNCTION_APP" --settings \
  EventHubsConnectionString="$EventHubsConnectionString" \
  EventHubConsumerGroup="$EVENTHUB_CONSUMER_GROUP" \
  EventHubName="$PRIMARY_EVENTHUB" \
  EventHubNamesCsv="$EVENTHUB_NAMES_CSV" \
  MessageEndpoint="$MessageEndpoint" \
  StreamOcid="$StreamOcid" \
  user="$user" \
  key_content="$KEY_ONELINE" \
  pass_phrase="$pass_phrase" \
  fingerprint="$fingerprint" \
  tenancy="$tenancy" \
  region="$region" \
  SCM_DO_BUILD_DURING_DEPLOYMENT="true" \
  ENABLE_ORYX_BUILD="true" >/dev/null

info "Packaging function..."
TMP_DIR="$(mktemp -d)"
TMP_ZIP="$TMP_DIR/azurelogs2oci.zip"
pushd "$FUNCTION_PATH" >/dev/null
# Remove any local .python_packages to avoid bundling platform-specific wheels
rm -rf .python_packages
zip -qry "$TMP_ZIP" .
popd >/dev/null

info "Deploying zip to Function App with remote build (Oryx)..."
az functionapp deployment source config-zip -g "$AZ_RG" -n "$AZ_FUNCTION_APP" --src "$TMP_ZIP" --build-remote true >/dev/null

# Persist latest values to .env for reuse
info "Updating $ENV_PATH with latest values..."
cat > "$ENV_PATH" <<EOF
# Generated by provision_azure_to_oci.sh
EventHubsConnectionString="$EventHubsConnectionString"
EventHubConsumerGroup="$EVENTHUB_CONSUMER_GROUP"
EventHubName="$PRIMARY_EVENTHUB"
EventHubNamesCsv="$EVENTHUB_NAMES_CSV"
EVENTHUB_RG="$AZ_RG"
EVENTHUB_NAMESPACE="$EVENTHUB_NAMESPACE"

MessageEndpoint="$MessageEndpoint"
StreamOcid="$StreamOcid"
OCI_MESSAGE_ENDPOINT="$MessageEndpoint"
OCI_STREAM_OCID="$StreamOcid"

user="$user"
key_content="$key_content"
KEY_FILE="${KEY_FILE:-}"
pass_phrase="$pass_phrase"
fingerprint="$fingerprint"
tenancy="$tenancy"
region="$region"

# Azure app + storage
AZ_RG="$AZ_RG"
AZ_LOCATION="$AZ_LOCATION"
AZ_STORAGE_ACCOUNT="$AZ_STORAGE_ACCOUNT"
AZ_FUNCTION_APP="$AZ_FUNCTION_APP"
AZ_PLAN="$AZ_PLAN"

# Optional script tuning
COUNT="${COUNT:-0}"
INACTIVITY_TIMEOUT="${INACTIVITY_TIMEOUT:-30}"
EOF

ok "Deployment complete."
info "Function App: $AZ_FUNCTION_APP (RG: $AZ_RG, Location: $AZ_LOCATION)"
info "Event Hubs namespace: $EVENTHUB_NAMESPACE | Hubs: $EVENTHUB_NAMES_CSV | Consumer group: $EVENTHUB_CONSUMER_GROUP"
info "OCI stream: $StreamOcid @ $MessageEndpoint"
info "Next: tail logs with 'az webapp log tail -g $AZ_RG -n $AZ_FUNCTION_APP'"
info "       or with Functions Core Tools: 'func azure functionapp logstream $AZ_FUNCTION_APP --resource-group $AZ_RG' (not supported on Linux Consumption; use premium plan or Application Insights Live Metrics)"
