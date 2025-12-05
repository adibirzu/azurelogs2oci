# EventHubsNamespaceToOCIStreaming (Timer-triggered Azure Function)

Purpose:
- Iterates one or more Event Hubs in a namespace and forwards all messages to Oracle Cloud Infrastructure (OCI) Streaming using the PutMessages API.
- Batching with 1MB and count limits, base64-encodes payloads as required by OCI.
- Timer trigger runs on a schedule (default: every minute) and processes each configured hub.

Folder contents:
- __init__.py: Function logic (Event Hub consumers + OCI sender)
- function.json: Timer binding (schedule)
- requirements.txt: Python deps (azure-functions, azure-eventhub, oci)
- host.json: Function host configuration

Supported configuration (App Settings):
- EventHubsConnectionString: Event Hubs namespace-level connection string (RootManageSharedAccessKey with Listen)
- EventHubConsumerGroup: Consumer group (default $Default). Use a dedicated group in production.
- EventHubNamesCsv: Comma-separated list of Event Hub entity names to process (e.g., insights-activity-logs, another-hub)
- MessageEndpoint or OCI_MESSAGE_ENDPOINT: OCI Streaming message endpoint (e.g., https://cell-1.streaming.<region>.oci.oraclecloud.com)
- StreamOcid or OCI_STREAM_OCID: Target OCI stream OCID
- OCI credentials:
  - user: OCI user OCID
  - key_content: Private key content (single-line supported; function rewraps to PEM)
  - pass_phrase: Optional
  - fingerprint: API key fingerprint
  - tenancy: OCI tenancy OCID
  - region: OCI region name
- Optional:
  - MaxBatchSize (default 100)
  - MaxBatchBytes (default 1048576)
  - InactivityTimeout (default 10 seconds per hub receive pass)

Deploy from Azure portal (custom template)
- Use deploy/azuredeploy.json with Azure Portal > Create a resource > Template deployment (custom). The template prompts for Function App name, Event Hubs connection, consumer group, CSV of hubs, OCI credentials, message endpoint, stream OCID, and optional batch sizes.
- Provide an HTTPS URL to the packaged zip (WEBSITE_RUN_FROM_PACKAGE) so the portal can deploy without CLI. You can generate the zip locally or use the GitHub Actions artifact described below.

Schedule:
- Default schedule (CRON): 0 */1 * * * * (every minute). Adjust in function.json.

Prerequisites:
- Azure:
  - Event Hubs namespace and hubs populated with logs
  - Azure subscription + permissions to create Function App and Storage
  - Consumer group for this function
- OCI:
  - Streaming Stream in target compartment
  - API signing keys configured for the user whose OCID is used
- Tools:
  - Azure CLI (az)
  - zip (or 7z) for packaging deploy artifacts

One-liner to list hub names and build EventHubNamesCsv:
az eventhubs eventhub list -g <rg> --namespace-name <namespace> --query "[].name" -o tsv | paste -sd, -

Local run (optional):
- Create EventHubsNamespaceToOCIStreaming/local.settings.json (do not check into source):
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "EventHubsConnectionString": "Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=...;",
    "EventHubConsumerGroup": "$Default",
    "EventHubNamesCsv": "insights-activity-logs",
    "MessageEndpoint": "https://cell-1.streaming.<region>.oci.oraclecloud.com",
    "StreamOcid": "ocid1.stream.oc1..xxxx",
    "user": "ocid1.user.oc1..xxxx",
    "key_content": "-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----",
    "pass_phrase": "",
    "fingerprint": "<fingerprint>",
    "tenancy": "ocid1.tenancy.oc1..xxxx",
    "region": "<oci-region>",
    "MaxBatchSize": "100",
    "MaxBatchBytes": "1048576",
    "InactivityTimeout": "10"
  }
}
- Run: func start

Deploy to Azure using Azure CLI (zip deploy):
1) Variables
RG="<resource-group>"
LOC="westeurope"
SA="<unique_storage_account_name>"
APP="<function_app_name>"

2) Resource group + storage + function app (Linux, Python 3.11, Functions v4)
az group create -n "$RG" -l "$LOC"
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS
az functionapp create -g "$RG" -n "$APP" --consumption-plan-location "$LOC" --runtime python --runtime-version 3.11 --functions-version 4 --os-type linux --storage-account "$SA"

3) App settings
# Event Hubs + consumer group
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  EventHubsConnectionString="Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=..." \
  EventHubConsumerGroup="$Default" \
  EventHubNamesCsv="insights-activity-logs,another-hub"

# OCI target
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  MessageEndpoint="https://cell-1.streaming.<region>.oci.oraclecloud.com" \
  StreamOcid="ocid1.stream.oc1..xxxx"

# OCI credentials (consider storing in Key Vault and referencing)
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  user="ocid1.user.oc1..xxxx" \
  key_content="-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----" \
  pass_phrase="" \
  fingerprint="<fingerprint>" \
  tenancy="ocid1.tenancy.oc1..xxxx" \
  region="<oci-region>"

# Optional tuning
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  MaxBatchSize="100" MaxBatchBytes="1048576" InactivityTimeout="10"

4) Package and deploy just this function folder
cd function/EventHubsNamespaceToOCIStreaming
zip -r ../../function-deploy.zip .
cd - 1>/dev/null
az functionapp deployment source config-zip -g "$RG" -n "$APP" --src "function-deploy.zip"

5) Validate logs and execution
az functionapp log tail -g "$RG" -n "$APP"

Operational notes:
- This function reads from @latest each run with a short inactivity window (InactivityTimeout per hub). For continuous processing, keep the 1-minute schedule; or increase schedule frequency.
- For checkpointing across runs, integrate Azure Blob checkpoint store (not included by default). Current design updates partition checkpoints in-session only.
- Use a dedicated consumer group to avoid interference with other consumers.
- Ensure the Function App has outbound access to OCI endpoints (consider firewall/vnet rules).
- Secure key_content via Azure Key Vault references in app settings for production.
- Helper script update: scripts/drain_eventhub_to_oci.sh now reads MessageEndpoint / StreamOcid from local.settings.json if OCI_MESSAGE_ENDPOINT / OCI_STREAM_OCID are not exported, preventing the “OCI_MESSAGE_ENDPOINT and/or OCI_STREAM_OCID not set” error during local validation.

Packaging options (zip for portal or CI/CD)
- Local zip: from repo root run
  python3 -m pip install -r function/EventHubsNamespaceToOCIStreaming/requirements.txt --target function/EventHubsNamespaceToOCIStreaming/.python_packages/lib/site-packages
  (cd function/EventHubsNamespaceToOCIStreaming && zip -qry ../../azurelogs2oci-function.zip .)
  Upload azurelogs2oci-function.zip to a storage container with a SAS URL and paste that URL into the portal template packageUri field.
- GitHub Actions: trigger .github/workflows/deploy-azure-function.yml (workflow_dispatch). It builds the zip, uploads it as an artifact, and can deploy directly when AZURE_FUNCTIONAPP_PUBLISH_PROFILE is provided as a secret.

Cleanup guidance (repo):
- You can retain this function folder as the authoritative multi-hub → OCI implementation.
- Candidate items to archive/remove if no longer needed: earlier experimental connectors or duplicate templates. Consider moving older folders into an archive/ directory for traceability.
