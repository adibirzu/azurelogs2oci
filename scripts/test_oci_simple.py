#!/usr/bin/env python3
"""
Simple OCI credentials test - focuses on authentication without Azure Functions dependencies
"""

import os
import sys
import re
from dotenv import load_dotenv

def parse_key(key_input: str) -> str:
    """Parse OCI private key from single-line format into PEM, tolerating trailing text"""
    try:
        import textwrap

        normalized = (key_input or "").replace("\\n", "\n").strip()

        begin_line = re.search(r'-----BEGIN [A-Z ]+-----', normalized).group()
        end_line = re.search(r'-----END [A-Z ]+-----', normalized).group()

        # Only keep the block between BEGIN/END to avoid extra tokens after the key
        key_block = normalized[normalized.index(begin_line) + len(begin_line) : normalized.index(end_line)]

        encr_lines = ''
        proc_type_line = re.search(r'Proc-Type: [^\n]+', key_block)
        dec_info_line = re.search(r'DEK-Info: [^\n]+', key_block)
        if proc_type_line:
            encr_lines += proc_type_line.group().strip() + '\n'
            key_block = key_block.replace(proc_type_line.group(), '')
        if dec_info_line:
            encr_lines += dec_info_line.group().strip() + '\n'
            key_block = key_block.replace(dec_info_line.group(), '')

        # Remove whitespace and wrap lines to PEM-friendly lengths
        body_compact = re.sub(r'\s+', '', key_block)
        wrapped_body = '\n'.join(textwrap.wrap(body_compact, 64))

        parts = [begin_line]
        if encr_lines:
            parts.append(encr_lines.rstrip('\n'))
        parts.append(wrapped_body)
        parts.append(end_line)
        return '\n'.join(parts)
    except Exception:
        raise Exception('Error while reading private key.')

def mask(value: str, keep: int = 6) -> str:
    """Mask secrets for logging."""
    if not value:
        return ""
    if len(value) <= keep:
        return "***"
    return f"{value[:keep]}...***"

def test_oci_credentials():
    """Test OCI credentials without Azure Functions dependencies"""

    print("=" * 80)
    print("🧪 OCI Credentials Test (Simplified)")
    print("=" * 80)
    print()

    # Try to load .env file
    env_candidates = [
        os.path.join(os.path.dirname(__file__), '.env'),
        os.path.join(os.path.dirname(__file__), '..', '.env'),
        os.path.join(os.path.dirname(__file__), '..', 'function', 'EventHubsNamespaceToOCIStreaming', '.env')
    ]

    env_loaded = False
    for env_file in env_candidates:
        if os.path.exists(env_file):
            print(f"📄 Loading environment from: {env_file}")
            load_dotenv(env_file)
            env_loaded = True
            break

    if not env_loaded:
        print("❌ No .env file found in candidate locations")

    # Check environment variables
    required_vars = ['user', 'key_content', 'fingerprint', 'tenancy', 'region', 'MessageEndpoint', 'StreamOcid']

    print("\n🔍 Environment Variables Check:")
    all_present = True
    for var in required_vars:
        value = os.getenv(var)
        if value:
            print(f"  ✅ {var}: {mask(value)}")
        else:
            print(f"  ❌ {var}: NOT SET")
            all_present = False

    if not all_present:
        print("\n❌ Missing required OCI environment variables!")
        print("\n🔧 For Azure Function deployment, ensure these are set in:")
        print("   Azure Portal → Function App → Configuration → Application Settings")
        print("\nRequired variables:")
        for var in required_vars:
            print(f"   - {var}")
        return False

    # Test OCI config building
    try:
        print("\n🔧 Testing OCI Configuration Building...")

        cfg = {
            "user": os.environ['user'],
            "key_content": parse_key(os.environ['key_content']),
            "pass_phrase": os.environ.get('pass_phrase', ''),
            "fingerprint": os.environ['fingerprint'],
            "tenancy": os.environ['tenancy'],
            "region": os.environ['region']
        }

        print("✅ OCI configuration built successfully")

        # Test OCI SDK validation
        import oci
        oci.config.validate_config(cfg)
        print("✅ OCI configuration validation passed")

        # Test endpoint and stream OCID
        endpoint = os.getenv("MessageEndpoint")
        stream_ocid = os.getenv("StreamOcid")

        if "streampool" in stream_ocid:
            print("❌ StreamOcid appears to be a Stream Pool OCID, not a Stream OCID")
            print("   Use the Stream OCID (ocid1.stream.oc1...) instead")
            return False

        print(f"✅ Message endpoint: {mask(endpoint)}")
        print(f"✅ Stream OCID: {mask(stream_ocid)}")

        # Test Stream client initialization
        print("\n🌐 Testing OCI Stream Client Initialization...")
        stream_client = oci.streaming.StreamClient(cfg, service_endpoint=endpoint)
        admin_client = oci.streaming.StreamAdminClient(cfg)
        print("✅ OCI Stream client initialized successfully")

        # Test authentication with a simple API call
        print("\n🔐 Testing OCI Authentication via StreamAdminClient.get_stream...")
        try:
            response = admin_client.get_stream(stream_ocid)
            print("✅ OCI authentication successful!")
            print(f"   Stream name: {response.data.name}")
            print(f"   Stream state: {response.data.lifecycle_state}")

        except oci.exceptions.ServiceError as e:
            if e.status == 404:
                print("⚠️  Stream not found - but authentication worked!")
                print("   This means your credentials are correct, but the stream OCID might be wrong")
                print(f"   Error: {e.message}")
            elif e.status == 401:
                print("❌ Authentication failed - invalid credentials")
                print(f"   Error: {e.message}")
                return False
            elif e.status == 403:
                print("❌ Authorization failed - user doesn't have permission")
                print(f"   Error: {e.message}")
                return False
            else:
                print(f"❌ OCI API error: HTTP {e.status} - {e.message}")
                return False

        except Exception as e:
            print(f"❌ Unexpected error during authentication: {e}")
            return False

    except Exception as e:
        print(f"❌ OCI configuration test failed: {e}")
        import traceback
        traceback.print_exc()
        return False

    print("\n" + "=" * 80)
    print("🎉 OCI CREDENTIALS TEST PASSED!")
    print("   ✅ All environment variables present")
    print("   ✅ OCI configuration valid")
    print("   ✅ Authentication successful")
    print("   ✅ Stream client can connect")
    print("=" * 80)

    print("\n📋 Next Steps for Azure Function:")
    print("1. ✅ OCI credentials are working")
    print("2. 🔄 Redeploy Azure Function with updated function.json (Event Hub trigger)")
    print("3. 📊 Check Azure Function logs for Event Hub trigger events")
    print("4. 🎯 Send test events to Event Hub and verify OCI Streaming receives them")

    return True

if __name__ == "__main__":
    success = test_oci_credentials()
    sys.exit(0 if success else 1)
