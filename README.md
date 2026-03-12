# Deployment of the Confidential Cluster Operator

This repository contains the helper scripts to install, deploy and test the Confidential Cluster Operator development release.

The installation happens on 2 clusters, the first one where the operator is deployed and the second one is the target cluster where we want to create confidential nodes.

## Installation of the operator on the external cluster
The `install-operator.sh` script sets up the Confidential Cluster Operator on an external cluster by first creating the catalog source in the OpenShift marketplace and then deploying the operator along with its required namespace and security context constraints. 

After waiting for the operator deployment to become available, the script extracts the necessary container image references from the operator's cluster service version and uses them to populate and apply the custom resource configuration with the cluster's ingress domain. 

Finally, it applies the approved image configuration and exposes the Key Broker Service and registration server as OpenShift routes, making them accessible for confidential node registration from the target cluster.
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

First, you need to apply the MachineConfiguration to point to the custom image:
```console
oc apply -f machine-config.yaml
```

Afterwards, we can create a machine set for confidential nodes using the script `create-machineset.sh`.

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
First, get the registration server URL from the external cluster where the operator is installed:
```console
oc get route register-server -n confidential-clusters -o jsonpath='{.spec.host}'
```

Then create the confidential MachineSet on the target cluster:
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

N.B For the image specification, you need to provide the path but without the subscription, this will be prefixed by the machinset automatically.

The script will create and apply the MachineSet. Scale up when ready:
```console
oc scale machineset <new-machineset-name> -n openshift-machine-api --replicas=1
```

