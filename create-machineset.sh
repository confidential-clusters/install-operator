#!/bin/bash

set -e

# Default values
REGISTRATION_SERVER=""
SOURCE_MACHINESET=""
NEW_MACHINESET_NAME=""
IMAGE=""
VM_SIZE="Standard_DC4ads_v5"
NAMESPACE="openshift-machine-api"

usage() {
    echo "Usage: $0 --registration-server <server-url> --source <machineset-name> --new-name <new-machineset-name> --image <resource-id> [options]"
    echo ""
    echo "Required:"
    echo "  --registration-server <url>    Registration server URL"
    echo "  --source <name>                Name of the source MachineSet to convert"
    echo "  --new-name <name>              Name for the new confidential MachineSet"
    echo "  --image <resource-id>          Image resource ID for confidential VM"
    echo ""
    echo "Optional:"
    echo "  --vm-size <size>               Confidential VM size (default: Standard_DC4ads_v5)"
    echo "  -h, --help                     Show this help message"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --registration-server)
      REGISTRATION_SERVER="$2"
      shift 2
      ;;
    --source)
      SOURCE_MACHINESET="$2"
      shift 2
      ;;
    --new-name)
      NEW_MACHINESET_NAME="$2"
      shift 2
      ;;
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --vm-size)
      VM_SIZE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1"
      usage
      ;;
  esac
done

# Validate required parameters
if [[ -z "$REGISTRATION_SERVER" ]]; then
  echo "Error: --registration-server is required"
  usage
fi

if [[ -z "$SOURCE_MACHINESET" ]]; then
  echo "Error: --source is required"
  usage
fi

if [[ -z "$NEW_MACHINESET_NAME" ]]; then
  echo "Error: --new-name is required"
  usage
fi

if [[ -z "$IMAGE" ]]; then
  echo "Error: --image is required"
  usage
fi

echo "Creating confidential MachineSet '$NEW_MACHINESET_NAME' from '$SOURCE_MACHINESET'..."
echo ""

echo "[1/3] Checking ignition secret..."
FILE=conf-node-ignition
IGNITION_SECRET=conf-ignition-secret

# Delete secret if it already exists
if oc get secret $IGNITION_SECRET -n $NAMESPACE &>/dev/null; then
  echo "      Secret $IGNITION_SECRET already exists, deleting it"
  oc delete secret $IGNITION_SECRET -n $NAMESPACE
fi

echo "      Creating ignition secret with registration server: $REGISTRATION_SERVER"
oc get secret worker-user-data -n $NAMESPACE -o jsonpath='{.data.userData}' \
  | base64 -d \
  | jq --arg url "http://$REGISTRATION_SERVER/ignition-clevis-pin-trustee" '.ignition.config.merge = [{"source": $url}] + .ignition.config.merge' > $FILE
oc create secret generic $IGNITION_SECRET -n $NAMESPACE --from-file=userData=$FILE
echo "      Ignition secret created successfully"
echo ""

echo "[2/3] Converting MachineSet to confidential computing configuration..."

if ! oc get machineset "$SOURCE_MACHINESET" -n "$NAMESPACE" &>/dev/null; then
  echo "Error: MachineSet '$SOURCE_MACHINESET' not found in namespace '$NAMESPACE'"
  exit 1
fi

oc get machineset "$SOURCE_MACHINESET" -n "$NAMESPACE" -o json | \
  jq --arg new_name "$NEW_MACHINESET_NAME" \
     --arg vm_size "$VM_SIZE" \
     --arg image "$IMAGE" \
  '
  # Remove metadata we do not need for the new resource
  del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .status) |

  # Update the name
  .metadata.name = $new_name |

  # Update labels to reflect new machineset name
  .metadata.labels["machine.openshift.io/cluster-api-machineset"] = $new_name |
  .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $new_name |
  .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $new_name |

  # Disable accelerated networking (not supported on DC-series VMs)
  .spec.template.spec.providerSpec.value.acceleratedNetworking = false |

  # Set confidential VM image resource ID and remove other image fields
  .spec.template.spec.providerSpec.value.image = {
    "resourceID": $image
  } |

  # Set VM size to confidential computing compatible size
  .spec.template.spec.providerSpec.value.vmSize = $vm_size |

  # Set userDataSecret to conf-ignition-secret (created in step 1)
  .spec.template.spec.providerSpec.value.userDataSecret.name = "conf-ignition-secret" |

  # Add security encryption type to managed disk
  .spec.template.spec.providerSpec.value.osDisk.managedDisk.securityProfile.securityEncryptionType = "VMGuestStateOnly" |

  # Set confidential VM security profile
  .spec.template.spec.providerSpec.value.securityProfile = {
    "settings": {
      "confidentialVM": {
        "uefiSettings": {
          "secureBoot": "Enabled",
          "virtualizedTrustedPlatformModule": "Enabled"
        }
      },
      "securityType": "ConfidentialVM"
    }
  } |

  # Set replicas to 0 for safety
  .spec.replicas = 0
  ' | yq -P > "${NEW_MACHINESET_NAME}.yaml"

echo "[3/3] Applying confidential MachineSet..."
oc apply -f "${NEW_MACHINESET_NAME}.yaml"
