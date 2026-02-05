#!/usr/bin/env python3
# -----------------------------------------------------------------
# setup_log_analytics.py
#
# Create OCI Log Analytics custom fields (22), JSON parser
# (26 field mappings), and source for Azure EntraID Audit Logs.
#
# This script handles the Log Analytics resources that have no
# Terraform provider support.  Run it after `terraform apply`
# to complete the pipeline.
#
# Auth (tried in order):
#   1. OCI Resource Principal  (OCI_RESOURCE_PRINCIPAL_VERSION set)
#   2. OCI config file         (~/.oci/config)
#   3. Environment variables   (OCI_USER_OCID, OCI_KEY_FILE, etc.)
#
# Prerequisites:
#   pip install oci     - OCI Python SDK (for field/parser creation)
#   oci CLI             - required for source creation (shells out to oci CLI)
#
# Required environment variables:
#   LA_NAMESPACE        - Log Analytics namespace
#   OCI_COMPARTMENT_ID  - Compartment OCID (for source creation)
#
# Optional (only for env-var auth):
#   OCI_REGION, OCI_USER_OCID, OCI_FINGERPRINT,
#   OCI_TENANCY_OCID, OCI_KEY_FILE or OCI_KEY_CONTENT
#
# Usage:
#   export LA_NAMESPACE="mynamespace"
#   export OCI_COMPARTMENT_ID="ocid1.compartment.oc1..xxx"
#   python3 stack/scripts/setup_log_analytics.py
# -----------------------------------------------------------------
import json
import os
import sys

import oci
from oci.log_analytics.models import (
    LogAnalyticsField,
    LogAnalyticsParserField,
    UpsertLogAnalyticsFieldDetails,
    UpsertLogAnalyticsParserDetails,
)


# -- Authentication ------------------------------------------------

def get_client():
    """Build LogAnalyticsClient with auto-detected auth."""

    # 1. Resource Principal (OCI Resource Manager / Container Instances)
    if os.environ.get("OCI_RESOURCE_PRINCIPAL_VERSION"):
        signer = oci.auth.signers.get_resource_principals_signer()
        return oci.log_analytics.LogAnalyticsClient({}, signer=signer)

    # 2. OCI config file (~/.oci/config)
    try:
        config = oci.config.from_file()
        oci.config.validate_config(config)
        return oci.log_analytics.LogAnalyticsClient(config)
    except Exception:
        pass

    # 3. Environment variables
    key_file = os.environ.get("OCI_KEY_FILE")
    key_content = os.environ.get("OCI_KEY_CONTENT")
    if key_file:
        with open(os.path.expanduser(key_file)) as f:
            key_pem = f.read()
    elif key_content:
        # Normalize PEM: handle escaped newlines from .env files
        key_pem = key_content.replace("\\n", "\n").strip()
    else:
        print("ERROR: No OCI credentials found.")
        print("  Set OCI config file (~/.oci/config), OCI_KEY_FILE, or")
        print("  run inside OCI Resource Manager.")
        sys.exit(1)

    config = {
        "user": os.environ["OCI_USER_OCID"],
        "key_content": key_pem,
        "pass_phrase": os.environ.get("OCI_KEY_PASSPHRASE", ""),
        "fingerprint": os.environ["OCI_FINGERPRINT"],
        "tenancy": os.environ["OCI_TENANCY_OCID"],
        "region": os.environ.get("OCI_REGION", ""),
    }
    return oci.log_analytics.LogAnalyticsClient(config)


# -- Field Definitions (22 custom fields) -------------------------

FIELD_DISPLAY_NAMES = [
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


# -- Parser Field Mappings (26 total) -----------------------------
# (display_name_or_builtin, json_path, sequence)

FIELD_MAPPINGS = [
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


# -- Example Log (exercises all 26 field mappings) -----------------

EXAMPLE_LOG = {
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
        {"Name": "RequestType", "Value": "OAuth2:Token"},
    ],
    "Actor": [
        {"ID": "91af402b-5540-4d3d-9029-ff26768def1e", "Type": 0},
        {"ID": "admin@example.com", "Type": 5},
    ],
    "ActorContextId": "3cd6474d-ca79-445c-a336-7e21738e935f",
    "ActorIpAddress": "203.0.113.50",
    "InterSystemsId": "2632722a-4354-471b-8356-08d44451f803",
    "IntraSystemId": "ec6869c2-b550-492c-a5f3-b29ee1bd1f43",
    "Target": [
        {"ID": "aea77556-60a8-479f-8afc-3c6ecfddbf1f", "Type": 0},
    ],
    "TargetContextId": "b4c245f3-521b-456d-9eb1-ca5a86d28394",
    "ApplicationId": "00000002-0000-0ff1-ce00-000000000000",
}


# -- Field Creation ------------------------------------------------

def create_fields(client, namespace):
    """Create or upsert all 22 custom fields.

    Returns a dict mapping display_name -> internal_name.
    """
    field_map = {}
    for display_name in FIELD_DISPLAY_NAMES:
        details = UpsertLogAnalyticsFieldDetails()
        details.display_name = display_name
        details.data_type = "String"
        details.is_multi_valued = False
        try:
            resp = client.upsert_field(namespace, details)
            field_map[display_name] = resp.data.name
            print(f"  Field OK     {resp.data.name:12s} -> {display_name}")
        except oci.exceptions.ServiceError:
            # Field may already exist; look it up
            try:
                fields = client.list_fields(
                    namespace, display_name_contains=display_name
                ).data.items
                for f in fields:
                    if f.display_name == display_name:
                        field_map[display_name] = f.name
                        print(f"  Field EXISTS {f.name:12s} -> {display_name}")
                        break
            except Exception as exc:
                print(f"  Field ERR: {display_name}: {exc}")
    return field_map


# -- Parser Creation -----------------------------------------------

PARSER_NAME = "azureEntraIDAuditJsonParser"


def create_parser(client, namespace, field_map):
    """Create or upsert the JSON parser with 26 field mappings."""
    parser_field_maps = []
    for name_or_display, json_path, seq in FIELD_MAPPINGS:
        internal = field_map.get(name_or_display, name_or_display)
        parser_field_maps.append(
            LogAnalyticsParserField(
                field=LogAnalyticsField(name=internal),
                parser_field_name=internal,
                parser_field_sequence=seq,
                storage_field_name=internal,
                structured_column_info=json_path,
            )
        )

    example_content = json.dumps(EXAMPLE_LOG, indent=2)

    parser_details = UpsertLogAnalyticsParserDetails(
        name=PARSER_NAME,
        display_name="Azure EntraID Audit JSON Parser",
        description=(
            "Parses Azure EntraID Audit logs with "
            "26 field mappings covering identity, operations, actors, "
            "and metadata fields. Supports multicloud monitoring with "
            "Cloud Provider = Azure."
        ),
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

    # Get existing etag for update (optimistic concurrency)
    etag = None
    try:
        existing = client.get_parser(namespace, PARSER_NAME)
        etag = existing.headers.get("etag")
    except oci.exceptions.ServiceError:
        pass

    kwargs = {"if_match": etag} if etag else {}
    result = client.upsert_parser(namespace, parser_details, **kwargs)
    print(f"  Parser OK: {result.data.name} ({len(result.data.field_maps)} field maps)")


# -- Source Creation -----------------------------------------------

SOURCE_NAME = "Azure EntraID Audit Logs"


def create_source(client, namespace, compartment_id):
    """Create the Log Analytics source referencing the parser."""
    # Check if source already exists
    try:
        existing = client.list_sources(
            namespace, compartment_id,
            name=SOURCE_NAME, is_system="ALL",
        )
        if existing.data.items:
            print(f"  Source EXISTS: {existing.data.items[0].name}")
            return
    except Exception:
        pass

    # Build source JSON for OCI CLI (SDK source upsert is complex)
    import subprocess
    import tempfile

    parsers_json = json.dumps(
        [{"name": PARSER_NAME, "isDefault": True}]
    )
    entity_types_json = json.dumps(
        [{"entityType": "oci_generic_resource",
          "entityTypeCategory": "Undefined",
          "entityTypeDisplayName": "OCI Generic Resource"}]
    )

    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as pf:
        pf.write(parsers_json)
        parsers_path = pf.name
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as ef:
        ef.write(entity_types_json)
        entity_path = ef.name

    try:
        cmd = [
            "oci", "log-analytics", "source", "upsert-source",
            "--namespace-name", namespace,
            "--name", "azureEntraIDAuditSource",
            "--display-name", SOURCE_NAME,
            "--description",
            "Azure EntraID Audit structured logs from Event Hub via OCI Streaming. "
            "Supports multicloud monitoring with Cloud Provider = Azure.",
            "--type-name", "os_file",
            "--is-system", "false",
            "--is-for-cloud", "false",
            "--parsers", f"file://{parsers_path}",
            "--entity-types", f"file://{entity_path}",
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            print(f"  Source created: {SOURCE_NAME}")
        else:
            print(f"  Source warning: {result.stderr[:200]}")
            print("  Source may need manual creation via OCI Console or setup_oci_log_analytics.sh")
    finally:
        os.unlink(parsers_path)
        os.unlink(entity_path)


# -- Main ----------------------------------------------------------

def main():
    namespace = os.environ.get("LA_NAMESPACE")
    compartment_id = os.environ.get("OCI_COMPARTMENT_ID")

    if not namespace:
        print("ERROR: LA_NAMESPACE environment variable is required")
        sys.exit(1)
    if not compartment_id:
        print("ERROR: OCI_COMPARTMENT_ID environment variable is required")
        sys.exit(1)

    print(f"Log Analytics namespace: {namespace}")
    print(f"Compartment: {compartment_id[:40]}...")
    print()

    client = get_client()

    print("--- Creating custom fields (22) ---")
    field_map = create_fields(client, namespace)
    print(f"  Total: {len(field_map)} fields\n")

    print("--- Creating JSON parser (26 field mappings) ---")
    create_parser(client, namespace, field_map)
    print()

    print("--- Creating Log Analytics source ---")
    create_source(client, namespace, compartment_id)
    print()

    print("Log Analytics custom content setup complete.")


if __name__ == "__main__":
    main()
