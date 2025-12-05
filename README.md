# azurelogs2oci

[![License: UPL](https://img.shields.io/badge/license-UPL-green)](https://img.shields.io/badge/license-UPL-green)

Azure Event Hubs to Oracle Cloud Infrastructure (OCI) Streaming: a minimal, production-ready implementation based on the oracle-devrel repo template.

This repository contains:
- A timer-triggered Azure Function that iterates one or more Event Hubs in a namespace and forwards all messages to OCI Streaming (PutMessages API).
- Simple scripts for ad-hoc draining and validation.
- Documentation to deploy and operate the solution.

## Introduction

azurelogs2oci forwards Azure Event Hub logs (e.g., Entra ID audit logs) to OCI Streaming by:
- Reading from configured Event Hubs using a namespace connection string and consumer group
- Batching records (1MB / count limits) and base64-encoding payloads as required by OCI
- Sending to a target OCI Streaming stream using API signing keys

The Function runs on a schedule (default: every minute), iterating the specified Event Hubs and delivering messages to OCI.

## Getting Started

The fastest way to deploy is with the function-specific quickstart.

- Quickstart (Function): function/EventHubsNamespaceToOCIStreaming/QUICKSTART.md
- Details and operational notes: function/EventHubsNamespaceToOCIStreaming/README.md
- Azure portal template (custom deployment): deploy/azuredeploy.json
- GitHub Actions manual zip deploy: .github/workflows/deploy-azure-function.yml

High-level steps:
1) Create or identify the Azure Event Hubs namespace and hubs carrying your logs.
2) Create an OCI Streaming stream and prepare OCI API signing keys.
3) Deploy the Function App (Linux, Python 3.11, Functions v4).
4) Configure App Settings:
   - EventHubsConnectionString, EventHubConsumerGroup, EventHubNamesCsv
   - MessageEndpoint (or OCI_MESSAGE_ENDPOINT), StreamOcid (or OCI_STREAM_OCID)
   - OCI credentials: user, key_content, pass_phrase (optional), fingerprint, tenancy, region
5) Zip-deploy the function folder and monitor logs.

## Prerequisites

- Azure
  - Event Hubs namespace with one or more hubs
  - Azure subscription and permission to create Function App + Storage
  - Azure CLI installed (az)
- OCI
  - An OCI Streaming Stream
  - OCI user with API signing keys (UPL license applies to this repository)
- Local
  - zip or 7z for packaging the function

## Repository Layout

- function/EventHubsNamespaceToOCIStreaming/
  - __init__.py: Function logic (Event Hub consumer + OCI sender)
  - function.json: Timer binding (default: every minute)
  - requirements.txt: azure-functions, azure-eventhub, oci
  - host.json: Function host configuration
  - README.md: Details and operational notes
  - QUICKSTART.md: Step-by-step deployment guide
- scripts/
  - drain_eventhub_to_oci.sh: Ad-hoc drain from a hub or all hubs in a namespace to OCI
  - eventhub_consumer.py: Consumer helper used by the drain script
- docs/
  - EVENT_FORMAT_DOCUMENTATION.md: Notes on expected event formats and metadata
  - blog-azurelogs-to-oci-streaming.md: Blog-ready walkthrough

## Notes/Issues

- Starting Position: The Function uses @latest per run with a short inactivity timeout to bound each pass. For backfill, use the scripts/drain_eventhub_to_oci.sh with --from-beginning or --start-iso.
- Checkpointing: Default code updates checkpoints within a session. For persistent cross-run checkpoints, integrate Azure Blob checkpoint store (not included by default).
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
