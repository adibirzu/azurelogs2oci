# ─────────────────────────────────────────────────────────────
# outputs.tf – Values needed by the Azure Function and for
#              post-deploy validation
# ─────────────────────────────────────────────────────────────

output "stream_pool_id" {
  description = "OCID of the Stream Pool"
  value       = oci_streaming_stream_pool.azure_pool.id
}

output "stream_id" {
  description = "OCID of the Stream (use as OCI_STREAM_OCID)"
  value       = oci_streaming_stream.azure_stream.id
}

output "stream_messaging_endpoint" {
  description = "Stream messaging endpoint URL (use as OCI_MESSAGE_ENDPOINT)"
  value       = oci_streaming_stream.azure_stream.messages_endpoint
}

output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap servers (for alternative Kafka-based integrations)"
  value       = oci_streaming_stream_pool.azure_pool.kafka_settings[0].bootstrap_servers
}

output "log_group_id" {
  description = "OCID of the Log Analytics log group"
  value       = oci_log_analytics_log_analytics_log_group.azure_logs.id
}

output "log_analytics_namespace" {
  description = "Log Analytics namespace"
  value       = local.la_namespace
}

output "service_connector_id" {
  description = "OCID of the Service Connector Hub"
  value       = oci_sch_service_connector.azure_bridge.id
}

output "env_snippet" {
  description = "Ready-to-paste values for .env"
  value       = <<-EOT
    OCI_STREAM_OCID=${oci_streaming_stream.azure_stream.id}
    OCI_STREAM_POOL_ID=${oci_streaming_stream_pool.azure_pool.id}
    OCI_MESSAGE_ENDPOINT=${oci_streaming_stream.azure_stream.messages_endpoint}
    OCI_LOG_ANALYTICS_NAMESPACE=${local.la_namespace}
  EOT
}
