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

## Create a confidential MachineSet
This script creates a confidential computing MachineSet by:
1. Creating an ignition secret with the registration server URL
2. Converting an existing MachineSet to confidential computing configuration
3. Applying the new MachineSet

The script will:
- Create `conf-ignition-secret` with the registration server URL
- Disable accelerated networking (not supported on DC-series VMs)
- Replace the image with the provided confidential VM-compatible image
- Set VM size to a confidential computing compatible size (default: Standard_DC4ads_v5)
- Set userDataSecret to `conf-ignition-secret`
- Add securityEncryptionType: VMGuestStateOnly to the managed disk
- Configure ConfidentialVM security profile with Secure Boot and vTPM
- Set replicas to 0 for safety

### Usage
First, get the registration server URL:
```console
oc get route register-server -n confidential-clusters -o jsonpath='{.spec.host}'
```

Then create the confidential MachineSet:
```console
./create-machineset.sh \
  --registration-server <registration-server-url> \
  --source <existing-machineset-name> \
  --new-name <new-machineset-name> \
  --image <image-resource-id> \
  [--vm-size <vm-size>]
```

Example:
```console
./create-machineset.sh \
  --registration-server register-server-confidential-clusters.apps.ci-ln-2br1qk2-1d09d.ci2.azure.devcluster.openshift.com \
  --source afrosi-test-h96rn-worker-germanywestcentral1 \
  --new-name machinset-conf-nodes \
  --image /resourceGroups/afrosi_group/providers/Microsoft.Compute/galleries/afrosi_gallery/images/rhcos-9.6.20260309-0-azure.x86_64/versions/0.1.0
```

The script will create and apply the MachineSet. Scale up when ready:
```console
oc scale machineset <new-machineset-name> -n openshift-machine-api --replicas=1
```

## Alternative: Convert an existing MachineSet separately
If you want to convert a MachineSet without creating the ignition secret (for testing or reusing an existing secret), use the standalone conversion script:

```console
./convert-to-confidential-machineset.sh --source <existing-machineset-name> --new-name <new-machineset-name> --image <image-resource-id> [--vm-size <vm-size>]
```

This generates a YAML file that you can review and apply manually:
```console
oc apply -f <new-machineset-name>.yaml
```
