#!/bin/bash

set -e

# shellcheck source=utils.sh
source "$(dirname "$0")/utils.sh"

# Check prerequisites
require_cmds oc

if ! oc whoami &>/dev/null; then
    echo "Error: not connected to any cluster. Please set KUBECONFIG or login with 'oc login'." >&2
    exit 1
fi

# Creation of the catalog for the operator
oc apply -f catalog-source.yaml
oc get catalogsource  -n openshift-marketplace confidential-cluster-operator-dev-preview

oc apply -f namespace.yaml
oc apply -f subscription.yaml
oc apply -f scc.yaml

# Installation of the operator
echo "Waiting for OLM to create the deployment resource..."
until oc get deployment confidential-cluster-operator -n confidential-clusters &> /dev/null; do
    sleep 1
done
oc wait --for=condition=Available deployment/confidential-cluster-operator -n confidential-clusters --timeout=300s

# Populate the CR
domain=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}')
sed "s|<DOMAIN>|$domain|g" cluster-cr.yaml | \
	oc apply -f -

# Install the approved image
oc apply -f approved-img.yaml

# Wait for kbs-service to exist
echo "Waiting for kbs-service to be created..."
until oc get svc kbs-service -n confidential-clusters &> /dev/null; do
    sleep 1
done

# Wait for register-server to exist
echo "Waiting for register-server to be created..."
until oc get svc register-server -n confidential-clusters &> /dev/null; do
    sleep 1
done

oc expose svc kbs-service -n confidential-clusters
oc expose svc register-server -n confidential-clusters
oc get routes -n confidential-clusters
