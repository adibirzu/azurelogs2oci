# Ship Azure logs to OCI Streaming with a 10-minute Azure Function deploy

Azure Event Hubs is a convenient landing zone for platform and Entra ID logs. When you also need those logs in Oracle Cloud Infrastructure (OCI) Streaming, you can bridge the two clouds with a tiny Python Azure Function. This walkthrough mirrors the style of the Oracle Sentinel connector guide but focuses on AzureLogs → OCI Streaming with a zip you can deploy directly from the Azure portal.

## Why this works well
- No servers to manage: consumption-based Linux Function App.
- Minimal code: one timer-triggered function that iterates your Event Hubs namespace.
- Safe batching: respects OCI 1MB/count limits and base64-encodes payloads.
- Bring your own keys: uses OCI API signing keys (user OCID, key content, fingerprint, tenancy, region).

## Prerequisites
- Azure subscription with an Event Hubs namespace carrying the logs you want.
- OCI Streaming stream created in your tenancy.
- OCI API key material (user OCID, private key, fingerprint, tenancy, region).
- A zip of the function (use the GitHub Actions artifact or package locally).

## Step 1: Package the function (or grab the workflow artifact)
Local option:
```bash
python3 -m pip install -r function/EventHubsNamespaceToOCIStreaming/requirements.txt \
  --target function/EventHubsNamespaceToOCIStreaming/.python_packages/lib/site-packages
(cd function/EventHubsNamespaceToOCIStreaming && zip -qry ../../azurelogs2oci-function.zip .)
# Upload azurelogs2oci-function.zip to blob storage with a SAS URL
```
GitHub Actions option:
- Trigger `.github/workflows/deploy-azure-function.yml` with `function_app_name` filled.
- Add secret `AZURE_FUNCTIONAPP_PUBLISH_PROFILE` (download from the Function App blade).
- The workflow builds the zip, deploys, and also publishes the artifact you can reuse in the portal.

## Step 2: Deploy from the Azure portal (custom template)
1) In the portal, choose **Create a resource** → **Template deployment (deploy using custom templates)**.  
2) Upload `deploy/azuredeploy.json`.  
3) Fill the fields (matches the on-screen form shown in the example screenshot):
   - Function App name and region.
   - Event Hubs connection string, consumer group, and `EventHubNamesCsv`.
   - OCI credentials: `user`, `key_content`, optional `pass_phrase`, `fingerprint`, `tenancy`, `region`.
   - Target stream: `MessageEndpoint` and `StreamOcid`.
   - Optional tuning: `MaxBatchSize`, `MaxBatchBytes`, `InactivityTimeout`.
   - `packageUri`: the HTTPS URL to your zip (SAS or GitHub release).
4) Review + create. The template provisions the storage account, consumption plan, Function App, and app settings, and points `WEBSITE_RUN_FROM_PACKAGE` at your zip.

## Step 3: Verify
- Open the Function App → **Log stream**. You should see partition start/close messages, batch flush counts, and OCI send status.
- Confirm messages arrive in your OCI Streaming stream.
- Adjust `EventHubNamesCsv` or batch settings in **Configuration** if needed.

## Troubleshooting tips
- Missing OCI settings locally? The helper script `scripts/drain_eventhub_to_oci.sh` now reads `MessageEndpoint` and `StreamOcid` from `local.settings.json` if `OCI_MESSAGE_ENDPOINT` / `OCI_STREAM_OCID` are not exported, avoiding the common “OCI_MESSAGE_ENDPOINT and/or OCI_STREAM_OCID not set” error.
- Connection issues: ensure the Function App has outbound access to `cell-*.streaming.<region>.oci.oraclecloud.com`.
- Backfill: run `scripts/drain_eventhub_to_oci.sh --from-beginning` with your Event Hub connection string to drain historical messages into OCI.

You now have a repeatable, portal-friendly way to mirror Azure logs into OCI Streaming with minimal moving parts. Happy shipping!
