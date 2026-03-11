#!/bin/bash

# Creation of the catalog for the operator
oc apply -f catalog-source.yaml
oc get catalogsource  -n openshift-marketplace cocl-workspace-test

oc apply -f namespace.yaml
oc apply -f subscription.yaml

# Installation of the operator
oc wait --for=condition=Available deployment/confidential-cluster-operator -n confidential-clusters --timeout=300s

# Populate the CR
domain=$(oc get ingress.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}')
sed "s/<DOMAIN>/$domain/g" cluster-cr.yaml \
	| oc apply -f -

# Install the approved image
oc apply -f approved-img.yaml
