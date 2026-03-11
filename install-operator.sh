#!/bin/bash

set -e

# Creation of the catalog for the operator
oc apply -f catalog-source.yaml
oc get catalogsource  -n openshift-marketplace cocl-workspace-test

oc apply -f namespace.yaml
oc apply -f subscription.yaml

# Installation of the operator
oc wait --for=condition=Available deployment/confidential-cluster-operator -n confidential-clusters --timeout=300s

# Populate the CR
domain=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}')
compute_img=$(oc get csv confidential-cluster-operator.v0.1.0 -n confidential-clusters -o json |\
  jq -r '.spec.relatedImages[] | select(.name == "compute-pcrs") | .image')
trustee_img=$(oc get csv confidential-cluster-operator.v0.1.0 -n confidential-clusters -o json |\
  jq -r '.spec.relatedImages[] | select(.name == "trustee") | .image')
reg_img=$(oc get csv confidential-cluster-operator.v0.1.0 -n confidential-clusters -o json |\
  jq -r '.spec.relatedImages[] | select(.name == "registration-server") | .image')
attest_reg_img=$(oc get csv confidential-cluster-operator.v0.1.0 -n confidential-clusters -o json |\
  jq -r '.spec.relatedImages[] | select(.name == "attestation-key-register") | .image')
sed "s|<DOMAIN>|$domain|g" cluster-cr.yaml | \
	sed "s|<COMPUTE-IMG>|$compute_img|g" |\
	sed "s|<TRUSTEE-IMG>|$trustee_img|g" |\
	sed "s|<REG-IMG>|$reg_img|g" |\
	sed "s|<ATTEST-REG-IMG>|$attest_reg_img|g" |\
	oc apply -f -

# Install the approved image
oc apply -f approved-img.yaml
