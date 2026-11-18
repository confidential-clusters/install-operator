# Getting started with a confidential cluster on OpenShift in Azure

This is a step-by-step guide to deploying a confidential cluster operator on an existing OpenShift cluster in Azure and creating a confidential node.

## Prerequisites

- An existing OpenShift cluster in Azure. For a guide on how to create an OpenShift cluster in Azure, see [Create an OpenShift cluster in Azure](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html-single/installing_on_azure).
- cert-manager installed in the OpenShift cluster. You can install it by running the following command:

```bash
kubectl apply -f \
    https://github.com/cert-manager/cert-manager/releases/download/v1.20.4/cert-manager.yaml
```

- CLI tools: `oc`, `az`, `make`.

## Operator installation

### Install an official release (file-based catalog)

This is the simplest way to install the operator. It uses the officially released images.

Step 1: Clone the `install-operator` repository:

```bash
git clone https://github.com/confidential-clusters/install-operator.git
```

Step 2: Inside the `install-operator` directory, run the following command to install the operator. Make sure `oc` is installed and that you are logged in to the OpenShift cluster.

```bash
./install-operator.sh
```

[TODO: The operator installation script currently uses the old catalog. It needs to be tested with the new catalog that will be used for GA. It may also be worth adding cert-manager installation to this script if cert-manager is not already installed on the cluster.]

### Build and install the operator

This is a more complicated process, primarily intended for developers who want to build and test the operator. For more information, see [Build and install the operator](https://github.com/trusted-execution-clusters/operator/blob/main/docs/usage/getting-started-guide.md#build-and-install-the-operator) in the upstream repository.

## Create a confidential node

Step 1: Download the officially released image. In the `install-operator` directory, run the following commands:

```bash
wget -4 [TODO: Add the link to the officially released image.]
gunzip [TODO: Add the name of the officially released image.]
```

Note: You can also build your own image. For instructions, see the [investigations repository](https://github.com/trusted-execution-clusters/investigations/tree/main#example-with-a-local-vm-attestation-and-disk-encryption).

Step 2: Upload the image to Azure. You can find the instructions in [Load image on Azure](https://github.com/confidential-clusters/install-operator/tree/main#load-image-on-azure).
Set `AZURE_RESOURCE_ID` to the resource ID of the uploaded image and `APPROVED_IMAGE` to the container image name.[TODO: Add the link to the officially released image.]

Step 3: Create a new confidential node. In the `install-operator` directory, run the following command:

```bash
AZURE_RESOURCE_ID="/resourceGroups/.../versions/0.1.0" \
APPROVED_IMAGE="quay.io/.../rhcos-confidential@sha256:..." \
python3 tests/create-confidential-node.py <operator-namespace> \
  --location <location> \
  --zone <zone> \
  --vm-size <vm-size> \
```

- The location and zone default to those of one of the existing worker nodes in the cluster.
- The VM size defaults to `Standard_DC2as_v5`.
- The location should match the location of the uploaded image.
- The location and zone should support your desired VM size and confidential VMs. You can check the supported VM sizes in [Azure Confidential VM options](https://learn.microsoft.com/en-us/azure/confidential-computing/virtual-machine-options) (make sure the TEE is AMD SEV-SNP).
- You can check whether the desired VM size is available in your location and zone by running the following command:

```bash
az vm list-skus \
  --location <location> \
  --resource-type virtualMachines \
  --size <vm-size> \
  --all \
  --output table
```

## Step 4: Verify that the confidential node is created. Run the following command:

Step 1: Get the list of machines in the cluster:

```bash
oc get machine -n openshift-machine-api
```

Find the node that was created with the confidential hardware.

Step 2: Check that the new machine in runing on sev-snp hardware. Run the following command:

```bash
oc debug node/<node-name> -- chroot /host dmesg | grep -i sev
```
