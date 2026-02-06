# ─────────────────────────────────────────────────────────────
# iam.tf – IAM policies for Service Connector Hub
#
# Grants SCH permission to read from OCI Streaming and write
# to Log Analytics in the target compartment.
# ─────────────────────────────────────────────────────────────

resource "oci_identity_policy" "sch_streaming" {
  count = var.create_iam_policies ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "azurelogs2oci-sch-streaming"
  description    = "Allow Service Connector Hub to read from OCI Streaming for the azurelogs2oci pipeline"

  statements = [
    "Allow any-user to use stream-pull in compartment id ${var.compartment_ocid} where all {request.principal.type='serviceconnector'}",
    "Allow any-user to use stream-consume in compartment id ${var.compartment_ocid} where all {request.principal.type='serviceconnector'}",
  ]
}

resource "oci_identity_policy" "sch_log_analytics" {
  count = var.create_iam_policies ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "azurelogs2oci-sch-log-analytics"
  description    = "Allow Service Connector Hub to write to Log Analytics for the azurelogs2oci pipeline"

  statements = [
    "Allow any-user to use log-analytics-log-group in compartment id ${var.compartment_ocid} where all {request.principal.type='serviceconnector'}",
  ]
}
