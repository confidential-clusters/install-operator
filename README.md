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
