#!/bin/bash

set -e

# Default values
REGISTRATION_SERVER=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --registration-server)
      REGISTRATION_SERVER="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 --registration-server <server-url>"
      echo ""
      echo "Required:"
      echo "  --registration-server <url>    Registration server URL"
      echo ""
      echo "Options:"
      echo "  -h, --help                     Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use -h or --help for usage information"
      exit 1
      ;;
  esac
done

# Validate required parameters
if [[ -z "$REGISTRATION_SERVER" ]]; then
  echo "Error: --registration-server is required"
  echo "Use -h or --help for usage information"
  exit 1
fi

echo "Creating MachineSet with registration server: $REGISTRATION_SERVER"

FILE=conf-node-ignition
IGNITION_SECRET=conf-ignition-secret
oc get secret worker-user-data -n openshift-machine-api -o jsonpath='{.data.userData}' \
  | base64 -d \
  | jq --arg url "http://$REGISTRATION_SERVER/ignition-clevis-pin-trustee" '.ignition.config.merge = [{"source": $url}] + .ignition.config.merge' > $FILE
oc create secret generic $IGNITION_SECRET -n openshift-machine-api --from-file=userData=$FILE

# Apply the machine set configuration
oc apply -f machine-set-conf-vm.yaml

echo "MachineSet created successfully"
