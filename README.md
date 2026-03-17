# Deployment of the Confidential Cluster Operator

This repository contains the helper scripts to install, deploy and test the Confidential Cluster Operator development release.

The installation happens on 2 clusters:
- **External cluster** (also called the **operator cluster**): Where the Confidential Cluster Operator and all trust services are installed
- **Target cluster**: Where confidential computing nodes are deployed and run workloads

## Installation of the operator on the external cluster
The `install-operator.sh` script sets up the Confidential Cluster Operator on an external cluster by first creating the catalog source in the OpenShift marketplace and then deploying the operator along with its required namespace and security context constraints. 

After waiting for the operator deployment to become available, the script applies the custom resource configuration with the cluster's ingress domain.

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

### Apply MachineConfig and MachineConfigPool

First, you need to apply the MachineConfiguration and MachineConfigPool to pin the RHCOS image for confidential VMs:
```console
oc apply -f machine-config.yaml
```

This file creates two resources:
- **MachineConfig** (`99-worker-cvm-image`): Specifies the custom RHCOS image URL with the role `worker-cvm`
- **MachineConfigPool** (`worker-cvm`): Manages nodes with the `node-role.kubernetes.io/worker-cvm` label

The MachineConfigPool ensures that the specified RHCOS image is **only applied to confidential nodes** created by the new machineset, not to existing worker nodes. This allows you to pin the OS version for confidential VMs while keeping regular workers on the default image.

After applying, wait for the rendered MachineConfig to be created:
```console
oc get mc | grep worker-cvm
```

### Create the MachineSet

Afterwards, we can create a machine set for confidential nodes using the script `create-machineset.sh`.

This script creates a confidential computing MachineSet by:
1. Creating `worker-user-data-cvm` secret pointing to the worker-cvm MachineConfigPool configuration
2. Creating `conf-ignition-secret` with the registration server URL merged into the worker-cvm ignition
3. Converting an existing MachineSet to confidential computing configuration with worker-cvm labels
4. Applying the new MachineSet

The script will:
- Create `worker-user-data-cvm` secret (points to `/config/worker-cvm` ignition endpoint)
- Create `conf-ignition-secret` with the registration server URL
- Add worker-cvm labels (`machine-role`, `machine-type`, `node-role.kubernetes.io/worker-cvm`)
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

**Important Notes:**
- For the image specification, you need to provide the path but without the subscription, this will be prefixed by the machineset automatically.
- **Choose the source machineset carefully**: The `--source` machineset is used as a **template** to inherit configuration like location, network settings, and resource group. Since the script will override the VM size to a confidential computing size (default: `Standard_DC4ads_v5`), you must choose a source machineset from a region that supports DC-series VMs (e.g., `eastus2`). The `Standard_DC4ads_v5` size may not be available in all regions like `eastus1`. To find available machinesets:
  ```console
  oc get machineset -n openshift-machine-api
  ```
  Look for machinesets in supported regions (typically `eastus2`, `westeurope`, `germanywestcentral`, etc.)
- **Adjusting after creation**: You can modify the zone or VM size after creation:
  ```console
  oc edit machineset <machineset-name> -n openshift-machine-api
  ```

The script will create and apply the MachineSet. Scale up when ready:
```console
oc scale machineset <new-machineset-name> -n openshift-machine-api --replicas=1
```

Wait for the node to join the cluster and verify it's managed by the worker-cvm MachineConfigPool:
```console
# Watch nodes being created
oc get nodes -w

# Verify the node has the worker-cvm role label
oc get nodes -l node-role.kubernetes.io/worker-cvm

# Verify the MachineConfigPool picked up the new node
oc get mcp worker-cvm
```

## Cleanup

Use the `clean-operator.sh` script to clean up resources from both clusters.

### Clean up operator from external cluster

Switch to the external cluster where the operator is installed:
```console
export KUBECONFIG=/path/to/external-cluster-kubeconfig
./clean-operator.sh --operator-cluster
```

This removes:
- Routes (kbs-service, register-server)
- Custom resources (ApprovedImage, TrustedExecutionCluster)
- Subscription and CSV
- OperatorGroup
- SecurityContextConstraints
- Namespace and CatalogSource

### Clean up machinesets from target cluster

Switch to the target cluster where machinesets are deployed:
```console
export KUBECONFIG=/path/to/target-cluster-kubeconfig
./clean-operator.sh --target-cluster
```

This removes:
- Confidential machinesets (scale down and delete)
- Secrets (`conf-ignition-secret`, `worker-user-data-cvm`)
- MachineConfigPool (`worker-cvm`)
- MachineConfig (`99-worker-cvm-image`)
- Temporary files

### Single Cluster Deployment

If the operator and machinesets are on the same cluster, you can clean up everything with:
```console
./clean-operator.sh --all
```

## Troubleshooting

### Enable Boot Diagnostics for Debugging
If you need to troubleshoot boot issues with confidential VMs, you can enable boot diagnostics to capture console output and screenshots during the boot process.

**Edit the machineset to add diagnostics**

Before scaling the machineset, use this command to edit it:
```console
oc edit machineset <machineset-name> -n openshift-machine-api
```

Add the diagnostics configuration under `spec.template.spec.providerSpec.value`:
```yaml
spec:
  template:
    spec:
      providerSpec:
        value:
          diagnostics:
            boot:
              customerManaged:
                storageAccountURI: https://<your-storage-account>.blob.core.windows.net/
              storageAccountType: CustomerManaged
```

**Note**: Replace `<your-storage-account>` with your Azure storage account name. The storage account must:
- Be in the same region as your VMs
- Have blob storage enabled
- Be accessible from the cluster's resource group

After enabling boot diagnostics, you can view console logs and screenshots in the Azure Portal:
1. Go to your VM in Azure Portal
2. Navigate to **Boot diagnostics** under **Help**
3. View the serial log and screenshot to debug boot issues

This is particularly useful for debugging ignition configuration issues or OS boot problems.

