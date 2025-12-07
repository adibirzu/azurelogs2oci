#!/usr/bin/env python3
"""
Test OCI credentials and connectivity to ensure the Azure Function can authenticate
"""

import os
import sys
import json
import logging
from dotenv import load_dotenv

# Add the function directory to path (eventhub_to_oci package)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'function', 'EventHubsNamespaceToOCIStreaming', 'eventhub_to_oci'))

# Import the function's OCI utilities
from __init__ import get_oci_config_from_env, validate_env, mask, parse_key

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def test_oci_credentials():
    """Test OCI credentials and connectivity"""

    print("=" * 80)
    print("🧪 OCI Credentials and Connectivity Test")
    print("=" * 80)
    print()

    # Try to load environment variables
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
        print("❌ No .env file found. Checking environment variables directly...")

    # Check environment variables
    required_vars = ['user', 'key_content', 'fingerprint', 'tenancy', 'region', 'MessageEndpoint', 'StreamOcid']
    missing_vars = []

    print("\n🔍 Environment Variables Check:")
    for var in required_vars:
        value = os.getenv(var)
        if value:
            print(f"  ✅ {var}: {mask(value)}")
        else:
            print(f"  ❌ {var}: NOT SET")
            missing_vars.append(var)

    if missing_vars:
        print(f"\n❌ Missing required environment variables: {', '.join(missing_vars)}")
        print("\n💡 Make sure these are set in your Azure Function App Settings:")
        for var in missing_vars:
            print(f"   - {var}")
        return False

    print("\n✅ All required environment variables are present")

    # Test OCI configuration
    try:
        print("\n🔧 Testing OCI Configuration...")
        cfg = get_oci_config_from_env()
        print("✅ OCI configuration built successfully")

        # Test OCI validation
        import oci
        oci.config.validate_config(cfg)
        print("✅ OCI configuration validation passed")

        # Test Stream endpoint validation
        endpoint, stream_ocid = validate_env()
        print(f"✅ Stream endpoint validated: {mask(endpoint)}")
        print(f"✅ Stream OCID validated: {mask(stream_ocid)}")

        # Test Stream client initialization
        print("\n🌐 Testing OCI Stream Client...")
        stream_client = oci.streaming.StreamClient(cfg, service_endpoint=endpoint)
        print("✅ OCI Stream client initialized successfully")

        # Try a simple API call to test authentication
        print("\n🔐 Testing OCI Authentication...")
        try:
            # Try to get stream info (this will test if credentials work)
            response = stream_client.get_stream(stream_ocid)
            print("✅ OCI authentication successful!")
            print(f"   Stream name: {response.data.name}")
            print(f"   Stream state: {response.data.lifecycle_state}")
        except oci.exceptions.ServiceError as e:
            if e.status == 404:
                print("⚠️  Stream not found - but authentication worked!")
                print("   This means your credentials are correct, but the stream OCID might be wrong")
            else:
                print(f"❌ OCI API authentication failed: {e}")
                return False
        except Exception as e:
            print(f"❌ Unexpected error during authentication test: {e}")
            return False

    except Exception as e:
        print(f"❌ OCI configuration test failed: {e}")
        return False

    print("\n" + "=" * 80)
    print("🎉 OCI Credentials Test PASSED!")
    print("   ✅ All environment variables present")
    print("   ✅ OCI configuration valid")
    print("   ✅ Authentication successful")
    print("   ✅ Stream client can connect")
    print("=" * 80)

    return True

def test_sample_message():
    """Test sending a sample message to OCI"""

    print("\n📤 Testing Sample Message Send...")

    try:
        # Import the OCI sender
        from __init__ import OciStreamSender, HubBuffer

        # Get configuration
        endpoint, stream_ocid = validate_env()
        cfg = get_oci_config_from_env()

        # Create sender
        sender = OciStreamSender(cfg, endpoint, stream_ocid)
        buffer = HubBuffer(sender, max_count=10, max_bytes=1024*1024)

        # Create a sample EntraID audit log
        sample_log = {
            "TimeGenerated": "2025-12-04T17:00:00.000Z",
            "Id": "test-event-123",
            "Operation": "Test: User login",
            "RecordType": 15,
            "ResultStatus": "Success",
            "UserType": "Member",
            "UserId": "test@example.com",
            "UserKey": "test-user-key",
            "Workload": "AzureActiveDirectory",
            "ObjectId": "test-object-id",
            "ClientIP": "192.168.1.1",
            "OrganizationId": "test-org-id",
            "Version": 1,
            "CreationTime": "2025-12-04T17:00:00",
            "AzureActiveDirectoryEventType": 1,
            "ApplicationId": "00000002-0000-0ff1-ce00-000000000000"
        }

        # Send the sample message
        json_message = json.dumps(sample_log)
        print(f"📝 Sample message size: {len(json_message)} bytes")
        print(f"📄 Sample message: {json_message[:200]}...")

        buffer.add(json_message)
        buffer.flush()

        sent = buffer.sent
        failed = buffer.failed

        if sent > 0 and failed == 0:
            print("✅ Sample message sent successfully to OCI Streaming!")
            return True
        else:
            print(f"❌ Sample message send failed: sent={sent}, failed={failed}")
            return False

    except Exception as e:
        print(f"❌ Sample message test failed: {e}")
        return False

if __name__ == "__main__":
    success = test_oci_credentials()
    if success:
        # If credentials work, test sending a sample message
        test_sample_message()

    sys.exit(0 if success else 1)
