#!/bin/bash

set -e

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
oc expose svc kbs-service -n confidential-clusters
oc expose svc register-server -n confidential-clusters
oc get routes -n confidential-clusters
