# Deployment of the Confidential Cluster Operator

This repository contains the helper scripts to install, deploy and test the Confidential Cluster Operator.

> **Dev preview:** For followers of the older developer preview release, a dedicated `developer-preview` branch is available in this repository.

The operator and confidential node are deployed on the same OpenShift cluster.

## Installation of the operator
The `install-operator.sh` script sets up the Confidential Cluster Operator on a cluster by first creating the catalog source in the OpenShift marketplace and then deploying the operator along with its required namespace and security context constraints.

After waiting for the operator deployment to become available, the script applies the custom resource configuration with the cluster's ingress domain.

Finally, it applies the approved image configuration and exposes the Key Broker Service and registration server as OpenShift routes for confidential node registration.
```console
./install-operator.sh
```

## Load image on Azure
Use the script to publish the VHD image under a user name and create the gallery
```console
./load-image-azure.sh -u <user> -i <vhd-image> [-l <location>]
```
The location defaults to `eastus` if not specified.

> **Note:** The image must be uploaded to the **same Azure region** as your target cluster.
> Azure Compute Gallery images are regional resources and cannot be referenced across regions.
> Uploading to the wrong region will cause MachineSet provisioning to fail when the nodes try to pull the image.

To find the region of your target cluster, run the following against it:
```console
oc get machineset -n openshift-machine-api \
  -o jsonpath='{.items[0].spec.template.spec.providerSpec.value.location}'
```

Alternatively, you can retrieve it from the cluster infrastructure object:
```console
oc get infrastructure cluster \
  -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' | \
  xargs -I{} az group show --name {} --query location -o tsv
```

Pass the resulting location to the script with the `-l` flag, for example:
```console
./load-image-azure.sh -u <user> -i <vhd-image> -l germanywestcentral
```

## Create a confidential MachineSet

Use `create-confidential-node.py` to generate and apply the required manifests.

Requirements:

- Python 3 with PyYAML installed (`python3 -m pip install PyYAML`).
- Logged into the cluster with `oc` or set `KUBECONFIG`.
- Operator already installed in <operator-namespace>.
- `AZURE_GALLERY_IMAGE`: Azure Compute Gallery image-version resource ID.
- `BOOTC_IMAGE`: matching bootc container image.
- --location and --zone: optional; must match an existing worker MachineSet and the location of the Azure Compute Gallery image.
- --vm-size: optional; defaults to Standard_DC2as_v5.

The script creates and applies a MachineConfig, MachineConfigPool, user-data Secret, and confidential MachineSet, then waits up to 15 minutes for one ready node.

```bash
AZURE_GALLERY_IMAGE="/resourceGroups/.../versions/0.1.0" \
BOOTC_IMAGE="quay.io/.../rhcos-confidential@sha256:..." \
python3 create-confidential-node.py <operator-namespace> \
  --location eastus \
  --zone 2 \
  --vm-size Standard_DC4ads_v5
```

## Cleanup

Use `clean-operator.sh` on the cluster containing both the operator and confidential node:

```console
./clean-operator.sh --all
```

The operator namespace defaults to `confidential-clusters`. To use another namespace:

```console
./clean-operator.sh --all --namespace roy-test-a0b76bf1
```

Use `--machines` to remove only the confidential MachineSet, MachineConfigPool, MachineConfig, user-data Secrets, and generated files for the selected operator namespace. Use `--operator` to remove only the operator. With `--all`, operator cleanup runs before machine cleanup, using the same cluster context.
