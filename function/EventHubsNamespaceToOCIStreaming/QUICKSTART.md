# QUICKSTART: Deploy EventHubsNamespaceToOCIStreaming to Azure and forward logs to OCI Streaming

This function consumes from one or more Azure Event Hubs (within a namespace) and forwards messages to Oracle Cloud Infrastructure (OCI) Streaming via the PutMessages API.

What you get
- Timer-triggered Azure Function (runs every minute by default)
- Reads from configured Event Hubs using a namespace connection string
- Batches messages and base64-encodes payloads as required by OCI Streaming
- Sends to your OCI Stream using API signing keys

Repo path
- Solutions/Oracle Cloud Infrastructure/Data Connectors/EventHubsNamespaceToOCIStreaming

Prerequisites
- Azure:
  - Event Hubs namespace with hubs (e.g., insights-activity-logs)
  - Azure subscription + permissions to create Function App and Storage
  - Azure CLI installed (az)
- OCI:
  - An OCI Streaming Stream created
  - API signing keys configured for your OCI user
- Local tools:
  - zip (or 7z) for packaging the function

1) Identify Event Hubs to consume
Use Azure CLI to list hubs in your namespace and build EventHubNamesCsv:
az eventhubs eventhub list -g <resource-group> --namespace-name <namespace> --query "[].name" -o tsv | paste -sd, -

Example:
- RG: ocitests
- Namespace: insights-activity-logs
- EventHubNamesCsv might be "insights-activity-logs" or a CSV like "hub1,hub2"

2) Create the Function App (Linux, Python 3.11, Functions v4)
Set variables:
RG="<resource-group>"
LOC="westeurope"
SA="<unique_storage_account_name>"
APP="<function_app_name>"

Create resources:
az group create -n "$RG" -l "$LOC"
az storage account create -g "$RG" -n "$SA" -l "$LOC" --sku Standard_LRS
az functionapp create -g "$RG" -n "$APP" --consumption-plan-location "$LOC" --runtime python --runtime-version 3.11 --functions-version 4 --os-type linux --storage-account "$SA"

3) Configure app settings
Required settings
- EventHubsConnectionString: Namespace-level connection string with Listen (RootManageSharedAccessKey)
- EventHubConsumerGroup: Consumer group name (e.g., $Default)
- EventHubNamesCsv: Comma-separated list of hub names
- MessageEndpoint: OCI messages endpoint (https://cell-1.streaming.<region>.oci.oraclecloud.com)
- StreamOcid: OCI Stream OCID
- OCI credentials:
  - user (OCI user OCID)
  - key_content (private key PEM; single-line supported)
  - pass_phrase (optional)
  - fingerprint (API key fingerprint)
  - tenancy (tenancy OCID)
  - region (OCI region name)

Example commands:
# Event Hubs + consumer group
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  EventHubsConnectionString="Endpoint=sb://<ns>.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=..." \
  EventHubConsumerGroup="$Default" \
  EventHubNamesCsv="insights-activity-logs"

# OCI target
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  MessageEndpoint="https://cell-1.streaming.<region>.oci.oraclecloud.com" \
  StreamOcid="ocid1.stream.oc1..xxxx"

# OCI credentials (consider Key Vault references in production)
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  user="ocid1.user.oc1..xxxx" \
  key_content="-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----" \
  pass_phrase="" \
  fingerprint="<fingerprint>" \
  tenancy="ocid1.tenancy.oc1..xxxx" \
  region="<oci-region>"

Optional tuning:
az functionapp config appsettings set -g "$RG" -n "$APP" --settings \
  MaxBatchSize="100" MaxBatchBytes="1048576" InactivityTimeout="10"

4) Package and deploy the function
cd "Solutions/Oracle Cloud Infrastructure/Data Connectors/EventHubsNamespaceToOCIStreaming"
zip -r ../../../../function-deploy.zip .
cd - 1>/dev/null
az functionapp deployment source config-zip -g "$RG" -n "$APP" --src "Solutions/function-deploy.zip"

5) Validate
- Tail logs:
  az functionapp log tail -g "$RG" -n "$APP"
- You should see partition start/close messages, batch flush logs, and OCI send results
- Verify messages arrive in your OCI Streaming stream

Notes and troubleshooting
- This function uses @latest as starting position per run, and uses a short inactivity window (InactivityTimeout) to end each receive pass. For continuous processing across hubs, keep the schedule frequent (default every minute).
- To retain checkpoints across runs, you can integrate Azure Blob Storage checkpointing (not included by default).
- Use a dedicated consumer group to avoid interfering with other consumers.
- Ensure outbound network access from the Function App to OCI endpoint.
- Secure key_content via Azure Key Vault (Key Vault references in app settings) for production.

Minimal local testing (optional)
Create a local.settings.json (do not commit):
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "python",
    "EventHubsConnectionString": "Endpoint=sb://...;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=...;",
    "EventHubConsumerGroup": "$Default",
    "EventHubNamesCsv": "insights-activity-logs",
    "MessageEndpoint": "https://cell-1.streaming.<region>.oci.oraclecloud.com",
    "StreamOcid": "ocid1.stream.oc1..xxxx",
    "user": "ocid1.user.oc1..xxxx",
    "key_content": "-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----",
    "pass_phrase": "",
    "fingerprint": "<fingerprint>",
    "tenancy": "ocid1.tenancy.oc1..xxxx",
    "region": "<oci-region>"
  }
}
Then:
func start

Repository cleanup status
- Legacy/duplicate connectors, ARM templates, and test/demo scripts were removed per your instruction.
- Current implementation of record: EventHubsNamespaceToOCIStreaming/ (this folder) and helper scripts:
  - drain_eventhub_to_oci.sh (ad-hoc drains; optional)
  - eventhub_consumer.py (ad-hoc drains; optional)

That’s it — your Function App will poll the configured Event Hubs and forward messages to OCI Streaming on the defined schedule.
