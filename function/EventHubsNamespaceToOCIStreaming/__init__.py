import json
import logging
import os
import time
from base64 import b64encode
from typing import List, Tuple

import azure.functions as func

# Azure Event Hubs (sync client)
try:
    from azure.eventhub import EventHubConsumerClient
    EH_SDK_OK = True
except Exception as e:
    EH_SDK_OK = False
    logging.error("Azure Event Hubs SDK missing. Add 'azure-eventhub' to requirements.txt")

# OCI SDK
try:
    import oci
    from oci.streaming.models import PutMessagesDetails, PutMessagesDetailsEntry
    OCI_SDK_OK = True
except Exception as e:
    OCI_SDK_OK = False
    logging.error("OCI SDK missing. Add 'oci' to requirements.txt")

logging.getLogger('azure.core.pipeline.policies.http_logging_policy').setLevel(logging.ERROR)

# Batch defaults
DEFAULT_MAX_BATCH_COUNT = int(os.getenv('MaxBatchSize', 100))
DEFAULT_MAX_BATCH_BYTES = int(os.getenv('MaxBatchBytes', 1024 * 1024))  # 1MB
DEFAULT_INACTIVITY_TIMEOUT = int(os.getenv('InactivityTimeout', 10))


def parse_key(key_input: str) -> str:
    """Parse OCI private key from single-line format into PEM"""
    try:
        import re
        begin_line = re.search(r'-----BEGIN [A-Z ]+-----', key_input).group()
        key_input = key_input.replace(begin_line, '')
        end_line = re.search(r'-----END [A-Z ]+-----', key_input).group()
        key_input = key_input.replace(end_line, '')

        encr_lines = ''
        proc_type_line = re.search(r'Proc-Type: [^ ]+', key_input)
        if proc_type_line:
            proc_type_line = proc_type_line.group()
            dec_info_line = re.search(r'DEK-Info: [^ ]+', key_input).group()
            encr_lines += proc_type_line + '\n'
            encr_lines += dec_info_line + '\n'
            key_input = key_input.replace(proc_type_line, '')
            key_input = key_input.replace(dec_info_line, '')

        body = key_input.strip().replace(' ', '\n')
        res = ''
        res += begin_line + '\n'
        if encr_lines:
            res += encr_lines + '\n'
        res += body + '\n'
        res += end_line
        return res
    except Exception:
        raise Exception('Error while reading private key.')


def get_oci_config_from_env() -> dict:
    """Build OCI config dict from environment variables (Function App settings)"""
    cfg = {
        "user": os.environ['user'],
        "key_content": parse_key(os.environ['key_content']),
        "pass_phrase": os.environ.get('pass_phrase', ''),
        "fingerprint": os.environ['fingerprint'],
        "tenancy": os.environ['tenancy'],
        "region": os.environ['region']
    }
    return cfg


class OciStreamSender:
    """Minimal OCI Stream sender with base64 encoding and size-aware batching"""

    def __init__(self, config: dict, message_endpoint: str, stream_ocid: str):
        oci.config.validate_config(config)
        self.client = oci.streaming.StreamClient(config, service_endpoint=message_endpoint)
        self.stream_ocid = stream_ocid

    @staticmethod
    def estimate_batch_bytes(messages: List[str]) -> int:
        # Estimate based on base64-encoded payloads + small overhead
        return sum(len(b64encode(m.encode('utf-8'))) for m in messages) + len(messages) * 50

    def send_batch(self, payloads: List[str]) -> Tuple[int, int]:
        if not payloads:
            return (0, 0)
        entries = [PutMessagesDetailsEntry(value=b64encode(p.encode('utf-8')).decode('utf-8')) for p in payloads]
        req = PutMessagesDetails(messages=entries)
        resp = self.client.put_messages(self.stream_ocid, req)
        sent = failed = 0
        for entry in (resp.data.entries or []):
            if getattr(entry, 'error', None):
                failed += 1
            else:
                sent += 1
        return (sent, failed)

    def send_with_limits(self, payloads: List[str], max_bytes: int, max_count: int) -> Tuple[int, int, int]:
        total_sent = total_failed = batches = 0
        batch: List[str] = []
        for p in payloads:
            candidate = batch + [p]
            if len(candidate) > max_count or self.estimate_batch_bytes(candidate) > max_bytes:
                s, f = self.send_batch(batch)
                total_sent += s
                total_failed += f
                batches += 1
                batch = [p]
            else:
                batch = candidate
        if batch:
            s, f = self.send_batch(batch)
            total_sent += s
            total_failed += f
            batches += 1
        return (total_sent, total_failed, batches)


class HubBuffer:
    """Buffer messages and flush to OCI by count/size or on-demand"""

    def __init__(self, sender: OciStreamSender, max_count: int, max_bytes: int):
        self.sender = sender
        self.max_count = max_count
        self.max_bytes = max_bytes
        self.buf: List[str] = []
        self.sent = 0
        self.failed = 0
        self.batches = 0

    def add(self, payload: str):
        self.buf.append(payload)
        self._flush_if_needed()

    def _flush_if_needed(self, force: bool = False):
        if not self.buf:
            return
        if force or len(self.buf) >= self.max_count or OciStreamSender.estimate_batch_bytes(self.buf) >= self.max_bytes:
            s, f, b = self.sender.send_with_limits(self.buf, self.max_bytes, self.max_count)
            self.sent += s
            self.failed += f
            self.batches += b
            self.buf.clear()
            logging.info(f"Flushed to OCI: sent={s}, failed={f}, batches={b}")

    def flush(self):
        self._flush_if_needed(force=True)


def process_eventhub(eh_conn: str, eh_name: str, consumer_group: str, sender: OciStreamSender,
                     inactivity_timeout: int, max_batch_count: int, max_batch_bytes: int):
    if not EH_SDK_OK:
        logging.error("Azure Event Hubs SDK not available in function runtime")
        return

    client = EventHubConsumerClient.from_connection_string(
        conn_str=eh_conn,
        consumer_group=consumer_group or "$Default",
        eventhub_name=eh_name
    )

    buffer = HubBuffer(sender, max_count=max_batch_count, max_bytes=max_batch_bytes)
    last_event_ts = time.time()

    def on_event(partition_context, event):
        nonlocal last_event_ts
        if event is None:
            return
        try:
            body = event.body_as_str(encoding="utf-8")
            buffer.add(body)
            last_event_ts = time.time()
            # Update checkpoint
            try:
                partition_context.update_checkpoint(event)
            except Exception:
                pass
        except Exception as ex:
            logging.warning(f"Error processing event in hub {eh_name}: {ex}")
            try:
                partition_context.update_checkpoint(event)
            except Exception:
                pass

    def on_error(partition_context, error):
        if partition_context:
            logging.error(f"Partition {partition_context.partition_id} error on {eh_name}: {error}")
        else:
            logging.error(f"General error on {eh_name}: {error}")

    def on_partition_initialize(partition_context):
        logging.info(f"Start partition {partition_context.partition_id} on {eh_name}")

    def on_partition_close(partition_context, reason):
        logging.info(f"Close partition {partition_context.partition_id} on {eh_name}: {reason}")

    logging.info(f"Receiving from Event Hub: {eh_name} (cg={consumer_group})")
    try:
        client.receive(
            on_event=on_event,
            on_error=on_error,
            on_partition_initialize=on_partition_initialize,
            on_partition_close=on_partition_close,
            starting_position="@latest",
            max_wait_time=inactivity_timeout
        )
    finally:
        # Ensure buffered messages are flushed
        buffer.flush()
        logging.info(f"Event Hub {eh_name} summary: sent={buffer.sent}, failed={buffer.failed}, batches={buffer.batches}")


def get_eventhub_list() -> List[str]:
    csv = os.getenv("EventHubNamesCsv", "")
    hubs = [h.strip() for h in csv.split(",") if h.strip()]
    if not hubs:
        logging.warning("EventHubNamesCsv is empty. Configure EventHubNamesCsv with a comma-separated list of hubs to process.")
    return hubs


def validate_env() -> Tuple[str, str, List[str]]:
    eh_conn = os.getenv("EventHubsConnectionString")
    if not eh_conn:
        raise RuntimeError("Missing EventHubsConnectionString application setting")

    endpoint = os.getenv("MessageEndpoint") or os.getenv("OCI_MESSAGE_ENDPOINT")
    stream_ocid = os.getenv("StreamOcid") or os.getenv("OCI_STREAM_OCID")
    if not endpoint or not stream_ocid:
        raise RuntimeError("Missing MessageEndpoint/StreamOcid (or OCI_MESSAGE_ENDPOINT/OCI_STREAM_OCID) application settings")

    hubs = get_eventhub_list()
    if not hubs:
        logging.warning("No Event Hubs configured to process (EventHubNamesCsv).")
    return endpoint, stream_ocid, hubs


def main(mytimer: func.TimerRequest) -> None:
    """Timer-triggered function: iterate configured Event Hubs and forward logs to OCI Streaming"""
    logging.info("Timer trigger: Event Hubs namespace → OCI Streaming start")

    if not (EH_SDK_OK and OCI_SDK_OK):
        logging.error("Required SDKs are not available. Ensure 'azure-eventhub' and 'oci' are installed.")
        return

    try:
        # Validate env and build OCI sender
        endpoint, stream_ocid, hubs = validate_env()
        cfg = get_oci_config_from_env()
        sender = OciStreamSender(cfg, endpoint, stream_ocid)

        eh_conn = os.getenv("EventHubsConnectionString")
        consumer_group = os.getenv("EventHubConsumerGroup", "$Default")
        inactivity_timeout = int(os.getenv("InactivityTimeout", DEFAULT_INACTIVITY_TIMEOUT))
        max_batch_count = int(os.getenv("MaxBatchSize", DEFAULT_MAX_BATCH_COUNT))
        max_batch_bytes = int(os.getenv("MaxBatchBytes", DEFAULT_MAX_BATCH_BYTES))

        if not hubs:
            logging.info("No hubs to process. Exiting.")
            return

        # Iterate hubs sequentially within one timer execution
        for hub in hubs:
            process_eventhub(
                eh_conn=eh_conn,
                eh_name=hub,
                consumer_group=consumer_group,
                sender=sender,
                inactivity_timeout=inactivity_timeout,
                max_batch_count=max_batch_count,
                max_batch_bytes=max_batch_bytes
            )

        logging.info("Timer trigger: processing complete.")

    except Exception as e:
        logging.exception(f"Timer function error: {e}")
