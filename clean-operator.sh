#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
# Namespaces
NAMESPACE="confidential-clusters"
MARKETPLACE_NAMESPACE="openshift-marketplace"
MACHINESET_NAMESPACE="openshift-machine-api"

# Secrets
IGNITION_SECRET="conf-ignition-secret"

# Temporary files
CONF_NODE_IGNITION="conf-node-ignition"

# Operator resources
SCC_NAME="confidential-clusters-trusted-cluster-scc"
CATALOG_NAME="confidential-cluster-operator-dev-preview"

# Target cluster resources
MACHINE_CONFIG="99-worker-custom-image"

usage() {
    echo "Usage: $0 [--operator-cluster] [--target-cluster] [--all]"
    echo ""
    echo "This script supports two deployment scenarios:"
    echo ""
    echo "Scenario 1: Single cluster (operator and machinesets on same cluster)"
    echo "  Use --all to clean everything"
    echo ""
    echo "Scenario 2: Two clusters (operator on cluster A, machinesets on cluster B)"
    echo "  Use --operator-cluster on external cluster A (where operator is installed)"
    echo "  Use --target-cluster on target cluster B (where machinesets are deployed)"
    echo ""
    echo "Options:"
    echo "  --operator-cluster        Clean operator resources (routes, CRs, subscription, namespace, etc.)"
    echo "  --target-cluster          Clean target cluster resources (machinesets, secrets, MachineConfig)"
    echo "  --all                     Clean both operator and target resources (single cluster scenario)"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Examples:"
    echo ""
    echo "  # Single cluster - clean everything:"
    echo "  $0 --all"
    echo ""
    echo "  # Two clusters - clean operator from external cluster:"
    echo "  export KUBECONFIG=/path/to/external-cluster-kubeconfig"
    echo "  $0 --operator-cluster"
    echo ""
    echo "  # Two clusters - clean machinesets from target cluster:"
    echo "  export KUBECONFIG=/path/to/target-cluster-kubeconfig"
    echo "  $0 --target-cluster"
    exit 1
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup_operator_cluster() {
    log_info "Starting cleanup of Confidential Cluster Operator from external cluster..."
    echo ""

    # Step 1: Delete routes
    log_info "[1/9] Deleting routes..."
    if oc get route kbs-service -n $NAMESPACE &>/dev/null; then
        oc delete route kbs-service -n $NAMESPACE
        log_info "      Deleted route: kbs-service"
    else
        log_warn "      Route kbs-service not found (already deleted or never created)"
    fi

    if oc get route register-server -n $NAMESPACE &>/dev/null; then
        oc delete route register-server -n $NAMESPACE
        log_info "      Deleted route: register-server"
    else
        log_warn "      Route register-server not found (already deleted or never created)"
    fi
    echo ""

    # Step 2: Delete ApprovedImage CR
    log_info "[2/9] Deleting ApprovedImage custom resource..."
    if oc get approvedimage rhcos -n $NAMESPACE &>/dev/null; then
        oc delete approvedimage rhcos -n $NAMESPACE
        log_info "      Deleted ApprovedImage: rhcos"
    else
        log_warn "      ApprovedImage rhcos not found (already deleted or never created)"
    fi
    echo ""

    # Step 3: Delete TrustedExecutionCluster CR
    log_info "[3/9] Deleting TrustedExecutionCluster custom resource..."
    if oc get trustedexecutioncluster confidential-cluster -n $NAMESPACE &>/dev/null; then
        oc delete trustedexecutioncluster confidential-cluster -n $NAMESPACE
        log_info "      Deleted TrustedExecutionCluster: confidential-cluster"
    else
        log_warn "      TrustedExecutionCluster confidential-cluster not found (already deleted or never created)"
    fi
    echo ""

    # Step 4: Delete Subscription
    log_info "[4/9] Deleting Subscription..."
    if oc get subscription confidential-clusters-sub -n $NAMESPACE &>/dev/null; then
        oc delete subscription confidential-clusters-sub -n $NAMESPACE
        log_info "      Deleted Subscription: confidential-clusters-sub"
    else
        log_warn "      Subscription confidential-clusters-sub not found (already deleted or never created)"
    fi
    echo ""

    # Step 5: Wait for CSV to be deleted
    log_info "[5/9] Waiting for ClusterServiceVersion to be deleted..."
    CSV_NAME=$(oc get csv -n $NAMESPACE -o name 2>/dev/null | grep confidential-cluster || true)
    if [ -n "$CSV_NAME" ]; then
        log_info "      Found CSV: $CSV_NAME"
        log_info "      Waiting for CSV deletion (timeout: 60s)..."
        oc wait --for=delete $CSV_NAME -n $NAMESPACE --timeout=60s 2>/dev/null || log_warn "      Timeout waiting for CSV deletion, continuing anyway..."
        log_info "      CSV deleted"
    else
        log_warn "      No ClusterServiceVersion found"
    fi
    echo ""

    # Step 6: Delete OperatorGroup
    log_info "[6/9] Deleting OperatorGroup..."
    if oc get operatorgroup confidential-clusters-og -n $NAMESPACE &>/dev/null; then
        oc delete operatorgroup confidential-clusters-og -n $NAMESPACE
        log_info "      Deleted OperatorGroup: confidential-clusters-og"
    else
        log_warn "      OperatorGroup confidential-clusters-og not found (already deleted or never created)"
    fi
    echo ""

    # Step 7: Delete SecurityContextConstraints
    log_info "[7/9] Deleting SecurityContextConstraints..."
    if oc get scc $SCC_NAME &>/dev/null; then
        oc delete scc $SCC_NAME
        log_info "      Deleted SCC: $SCC_NAME"
    else
        log_warn "      SCC $SCC_NAME not found (already deleted or never created)"
    fi
    echo ""

    # Step 8: Delete Namespace
    log_info "[8/9] Deleting namespace..."
    if oc get namespace $NAMESPACE &>/dev/null; then
        oc delete namespace $NAMESPACE
        log_info "      Deleted namespace: $NAMESPACE"
        log_info "      Waiting for namespace deletion (timeout: 120s)..."
        oc wait --for=delete namespace/$NAMESPACE --timeout=120s 2>/dev/null || log_warn "      Timeout waiting for namespace deletion, continuing anyway..."
    else
        log_warn "      Namespace $NAMESPACE not found (already deleted or never created)"
    fi
    echo ""

    # Step 9: Delete CatalogSource
    log_info "[9/9] Deleting CatalogSource..."
    if oc get catalogsource $CATALOG_NAME -n $MARKETPLACE_NAMESPACE &>/dev/null; then
        oc delete catalogsource $CATALOG_NAME -n $MARKETPLACE_NAMESPACE
        log_info "      Deleted CatalogSource: $CATALOG_NAME"
    else
        log_warn "      CatalogSource $CATALOG_NAME not found (already deleted or never created)"
    fi
    echo ""

    log_info "✓ Operator cluster cleanup completed!"
}

scale_machineset_to_zero() {
    local machineset_name="$1"
    local CURRENT_REPLICAS

    CURRENT_REPLICAS=$(oc get machineset "$machineset_name" -n $MACHINESET_NAMESPACE -o jsonpath='{.spec.replicas}')
    if [ "$CURRENT_REPLICAS" -gt 0 ]; then
        log_info "      Scaling down machineset: $machineset_name (replicas: $CURRENT_REPLICAS -> 0)"
        oc scale machineset "$machineset_name" -n $MACHINESET_NAMESPACE --replicas=0
    else
        log_info "      MachineSet $machineset_name already scaled to 0"
    fi
}

scale_and_collect_machinesets() {
    local -n machinesets_array=$1  # nameref to return array
    local wait_time=$2

    for ms in "${machinesets_array[@]}"; do
        scale_machineset_to_zero "$ms"
    done

    if [ ${#machinesets_array[@]} -gt 0 ]; then
        log_info "      Waiting for machines to be deleted..."
        sleep "$wait_time"
    fi
}

delete_machinesets() {
    local -n machinesets_array=$1  # nameref to array

    if [ ${#machinesets_array[@]} -eq 0 ]; then
        log_warn "      No machinesets to delete"
        return
    fi

    for ms in "${machinesets_array[@]}"; do
        oc delete machineset "$ms" -n $MACHINESET_NAMESPACE
        log_info "      Deleted machineset: $ms"
        # Delete the generated YAML file if it exists
        if [ -f "${ms}.yaml" ]; then
            rm -f "${ms}.yaml"
            log_info "      Deleted generated file: ${ms}.yaml"
        fi
    done
}

delete_secret_with_file() {
    local secret_name="$1"
    local file_path="$2"

    if oc get secret "$secret_name" -n $MACHINESET_NAMESPACE &>/dev/null; then
        oc delete secret "$secret_name" -n $MACHINESET_NAMESPACE
        log_info "      Deleted secret: $secret_name"

        if [ -n "$file_path" ] && [ -f "$file_path" ]; then
            rm -f "$file_path"
            log_info "      Deleted temporary file: $file_path"
        fi
    else
        log_warn "      Secret $secret_name not found (already deleted or never created)"
    fi
}

cleanup_target_cluster() {
    log_info "Starting cleanup of confidential resources from target cluster..."
    echo ""

    # Step 1: Find and scale down confidential machinesets
    log_info "[1/4] Finding and scaling down confidential machinesets..."

    # Find all machinesets using conf-ignition-secret (confidential machinesets)
    MACHINESETS_TO_DELETE=($(oc get machineset -n $MACHINESET_NAMESPACE -o json | \
        jq -r --arg secret "$IGNITION_SECRET" '.items[] | select(.spec.template.spec.providerSpec.value.userDataSecret.name == $secret) | .metadata.name'))

    if [ ${#MACHINESETS_TO_DELETE[@]} -eq 0 ]; then
        log_warn "      No confidential machinesets found (no machinesets using $IGNITION_SECRET)"
    else
        log_info "      Found ${#MACHINESETS_TO_DELETE[@]} confidential machineset(s)"
        scale_and_collect_machinesets MACHINESETS_TO_DELETE 10
    fi
    echo ""

    # Step 2: Delete machinesets
    log_info "[2/4] Deleting confidential machinesets..."
    delete_machinesets MACHINESETS_TO_DELETE
    echo ""

    # Step 3: Delete ignition secret
    log_info "[3/4] Deleting ignition secret..."
    delete_secret_with_file "$IGNITION_SECRET" "$CONF_NODE_IGNITION"
    echo ""

    # Step 4: Delete MachineConfig
    log_info "[4/4] Deleting MachineConfig..."
    if oc get machineconfig $MACHINE_CONFIG &>/dev/null; then
        oc delete machineconfig $MACHINE_CONFIG
        log_info "      Deleted MachineConfig: $MACHINE_CONFIG"
    else
        log_warn "      MachineConfig $MACHINE_CONFIG not found"
    fi
    echo ""

    log_info "✓ Target cluster cleanup completed!"
}

# Check prerequisites
if ! command -v oc &>/dev/null; then
    log_error "oc command not found. Please install OpenShift CLI."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    log_error "jq command not found. Please install jq."
    exit 1
fi

if ! oc whoami &>/dev/null; then
    log_error "Not connected to any cluster. Please set KUBECONFIG or login with 'oc login'."
    exit 1
fi

# Parse command line arguments
CLEAN_OPERATOR=false
CLEAN_TARGET=false

if [ $# -eq 0 ]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator-cluster)
            CLEAN_OPERATOR=true
            shift
            ;;
        --target-cluster)
            CLEAN_TARGET=true
            shift
            ;;
        --all)
            CLEAN_OPERATOR=true
            CLEAN_TARGET=true
            shift
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

# Validate flags
if [ "$CLEAN_OPERATOR" = false ] && [ "$CLEAN_TARGET" = false ]; then
    log_error "Must specify at least one action: --operator-cluster, --target-cluster, or --all"
    usage
fi

# Execute cleanup based on flags
if [ "$CLEAN_OPERATOR" = true ]; then
    cleanup_operator_cluster
    echo ""
fi

if [ "$CLEAN_TARGET" = true ]; then
    cleanup_target_cluster
    echo ""
fi

log_info "All cleanup operations completed successfully!"
