# azurelogs2oci

[![License: UPL](https://img.shields.io/badge/license-UPL-green)](https://img.shields.io/badge/license-UPL-green)

Azure Event Hubs to Oracle Cloud Infrastructure (OCI) Streaming: a minimal, production-ready implementation based on the oracle-devrel repo template.

This repository contains:
- An Event Hub-triggered Azure Function that forwards events to OCI Streaming (PutMessages API) with batching and base64 encoding.
- Helper scripts for ad-hoc draining and validation.
- Documentation, quickstarts, and a blog-style guide with console screenshots/placeholders.

## Introduction

azurelogs2oci forwards Azure Event Hub logs (e.g., Entra ID audit logs) to OCI Streaming by:
- Triggering directly from a chosen Event Hub (Function binding) using a namespace connection string + consumer group.
- Batching records (1MB / count limits) and base64-encoding payloads as required by OCI.
- Sending to a target OCI Streaming stream using API signing keys.

## Getting Started

The fastest way to deploy is with the function-specific quickstart.

- Quickstart (Function): function/EventHubsNamespaceToOCIStreaming/QUICKSTART.md
- Details and operational notes: function/EventHubsNamespaceToOCIStreaming/README.md
- Azure portal template (custom deployment): deploy/azuredeploy.json
- GitHub Actions manual zip deploy: .github/workflows/deploy-azure-function.yml

High-level steps:
1) Create or identify the Azure Event Hubs namespace and the hub carrying your logs.
2) Create an OCI Streaming stream and prepare OCI API signing keys (fingerprint must match the private key you deploy).
3) Deploy the Function App (Linux, Python 3.11, Functions v4) and bind the Event Hub trigger (EventHubName).
4) Configure App Settings:
   - EventHubsConnectionString, EventHubConsumerGroup, EventHubName (for the trigger), EventHubNamesCsv (scripts only)
   - MessageEndpoint (or OCI_MESSAGE_ENDPOINT), StreamOcid (or OCI_STREAM_OCID)
   - OCI credentials: user, key_content, pass_phrase (optional), fingerprint (matching the private key), tenancy, region
5) Zip-deploy the function folder and monitor logs.
- The provision script auto-resolves the namespace connection string (RootManageSharedAccessKey), installs Python deps into `.python_packages`, and zips the function for deployment.

## Prerequisites

- Azure
  - Event Hubs namespace with one or more hubs
  - Azure subscription and permission to create Function App + Storage
  - Azure CLI installed (az)
- OCI
  - An OCI Streaming Stream
  - OCI user with API signing keys
- Local
  - zip or 7z for packaging the function

## Repository Layout

- function/EventHubsNamespaceToOCIStreaming/
  - eventhub_to_oci/__init__.py: Function logic (Event Hub trigger + OCI sender)
  - eventhub_to_oci/function.json: Event Hub trigger binding (real-time)
  - requirements.txt: azure-functions, azure-eventhub, oci
  - host.json: Function host configuration
  - README.md: Details and operational notes
  - QUICKSTART.md: Step-by-step deployment guide
- scripts/
  - drain_eventhub_to_oci.sh: Ad-hoc drain from a hub or all hubs in a namespace to OCI
  - eventhub_consumer.py: Consumer helper used by the drain script
  - setup_eventhub_to_oci.sh: Interactive helper to collect Azure/OCI settings and write a local .env
  - provision_azure_to_oci.sh: One-shot creator (RG, storage, Function App), sets app settings, packages, and deploys the function
- docs/
  - EVENT_FORMAT_DOCUMENTATION.md: Notes on expected event formats and metadata
  - blog-azurelogs-to-oci-streaming.md: Blog-ready walkthrough

Local smoke test
- Copy .env.example to .env (kept out of git) and fill Event Hubs connection + OCI settings. Use the OCI *stream* OCID (not the stream pool OCID) in StreamOcid/OCI_STREAM_OCID; or run `./scripts/setup_eventhub_to_oci.sh` to auto-discover hubs and build .env interactively.
- Run `./scripts/drain_eventhub_to_oci.sh --from-beginning` to drain locally and verify messages reach OCI Streaming.
- For full provisioning + deployment from scratch, run `./scripts/provision_azure_to_oci.sh` (creates RG/storage/Function App, configures settings, zips, and deploys).

Tail function logs (CLI options)
- `az webapp log tail -g <rg> -n <app>`
- or `func azure functionapp logstream <app> --resource-group <rg>` if you have Functions Core Tools
- Note: Azure CLI/Core Tools logstream is not supported on Linux Consumption. Use `--plan premium` during provisioning (EP1) or open Application Insights Live Metrics in the portal.
- Look for "Config summary" and "summary: sent=..." lines to confirm settings from provisioning are applied and messages are forwarded.
- If logs show a warning about StreamOcid pointing to a Stream Pool (ocid1.streampool...), switch the setting to the Stream OCID (ocid1.stream...).

## Notes/Issues

- Trigger behavior: The Function uses an Event Hub trigger bound to `EventHubName` and reads continuously from the configured consumer group. Use the drain script for backfill (`--from-beginning` or `--start-iso`).
- Checkpointing: Default binding checkpoints within a session. For persistent cross-run checkpoints, integrate Azure Blob checkpoint store (not included by default).
- Consumer Group: Use a dedicated consumer group to avoid interfering with other consumers.
- Networking: Ensure outbound access from the Function App to OCI Streaming endpoints.

## URLs

- Azure Functions: https://learn.microsoft.com/azure/azure-functions/
- Azure Event Hubs: https://learn.microsoft.com/azure/event-hubs/
- OCI Streaming: https://docs.oracle.com/en-us/iaas/Content/Streaming/home.htm

## Contributing

This project welcomes contributions from the community. Before submitting a pull
request, please [review our contribution guide](./CONTRIBUTING.md).

## Security

Please consult the [security guide](./SECURITY.md) for our responsible security
vulnerability disclosure process.

## License

Copyright (c) 2024 Oracle and/or its affiliates.

Licensed under the Universal Permissive License (UPL), Version 1.0.

See [LICENSE](LICENSE.txt) for more details.

ORACLE AND ITS AFFILIATES DO NOT PROVIDE ANY WARRANTY WHATSOEVER, EXPRESS OR IMPLIED, FOR ANY SOFTWARE, MATERIAL OR CONTENT OF ANY KIND CONTAINED OR PRODUCED WITHIN THIS REPOSITORY, AND IN PARTICULAR SPECIFICALLY DISCLAIM ANY AND ALL IMPLIED WARRANTIES OF TITLE, NON-INFRINGEMENT, MERCHANTABILITY, AND FITNESS FOR A PARTICULAR PURPOSE.  FURTHERMORE, ORACLE AND ITS AFFILIATES DO NOT REPRESENT THAT ANY CUSTOMARY SECURITY REVIEW HAS BEEN PERFORMED WITH RESPECT TO ANY SOFTWARE, MATERIAL OR CONTENT CONTAINED OR PRODUCED WITHIN THIS REPOSITORY. IN ADDITION, AND WITHOUT LIMITING THE FOREGOING, THIRD PARTIES MAY HAVE POSTED SOFTWARE, MATERIAL OR CONTENT TO THIS REPOSITORY WITHOUT ANY REVIEW. USE AT YOUR OWN RISK.

## Publishing

You can publish this repository to GitHub under the desired organization/name (e.g., azurelogs2oci):

- Create the empty repository in your GitHub org (e.g., https://github.com/<org>/azurelogs2oci)
- Point this local clone at the new remote and push:

```bash
cd azurelogs2oci
git remote remove origin
git remote add origin git@github.com:<org>/azurelogs2oci.git
git push -u origin main
```

Alternatively, use the GitHub CLI (gh) to create and push the repository.
