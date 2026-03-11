# Deployment of the Confidential Cluster Operator

This repository contains the helper scripts to install, deploy and test the Confidential Cluster Operator development release.

## Installation of the operator on the external cluster
The script `install-operator` creates the catalog entries for the operator, deploys the operator in the `confidential-clusters` namespace, and it creates the routes for the required endpoint
```console
./install-operator.sh
```

## Load image on Azure
Use the script to publish the VHD image under a user name and create the gallery
```console
./load-image-azure.sh -u <user> -i <vhd-image> [-l <location>]
```
The location defaults to `eastus` if not specified.

### Create the machine set with the registration url 
Get the url of the registration-server where the confidential cluster operator is installed:
```console
oc get route register-server -n confidential-clusters -o jsonpath='{.spec.host}'
```
Create the machine set with the url you retrieved from the previous command:
```console
./create-machineset.sh --registration-server register-server-confidential-clusters.apps.ci-ln-2br1qk2-1d09d.ci2.azure.devcluster.openshift.com
```
