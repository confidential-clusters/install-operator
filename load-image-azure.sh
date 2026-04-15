#!/bin/bash

# SPDX-FileCopyrightText: Alice Frosi <afrosi@redhat.com>
#
# SPDX-License-Identifier: CC0-1.0
set -xe

IMAGE=""
USER=""
LOCATION="eastus"
FORCE=false

usage() {
    echo "Usage: $0 -i <image> -u <user> [-l <location>] [-f]"
    echo "  -i    Image file (VHD) to upload"
    echo "  -u    User name for resource naming"
    echo "  -l    Azure location (default: eastus)"
    echo "  -f    Force overwrite of existing blob"
    exit 1
}

while getopts "i:u:l:f" opt; do
    case $opt in
        i)
            IMAGE="$OPTARG"
            ;;
        u)
            USER="$OPTARG"
            ;;
        l)
            LOCATION="$OPTARG"
            ;;
        f)
            FORCE=true
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "$IMAGE" ]; then
    echo "Error: Image is required"
    usage
fi

if [ -z "$USER" ]; then
    echo "Error: User is required"
    usage
fi

resource_group=${USER}_group
storage_account=$USER
storage_container=${USER}-con
compute_gallery=${USER}_gallery
image_version=0.1.0
image="$IMAGE"
image_definition=$(basename "$image" .vhd)

az login
AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)

if ! az group show --name $resource_group &>/dev/null; then
  echo "Creating resource group $resource_group..."
  az group create --name $resource_group --location $LOCATION
fi

actual_storage_rg=$resource_group
if ! az storage account show --name $storage_account --resource-group $resource_group &>/dev/null; then
  existing_rg=$(az storage account list --query "[?name=='$storage_account'].resourceGroup" -o tsv 2>/dev/null)
  if [ -n "$existing_rg" ]; then
    echo "Storage account '$storage_account' already exists in resource group '$existing_rg', skipping creation..."
    actual_storage_rg=$existing_rg
  else
    echo "Creating storage account $storage_account..."
    az storage account create --name $storage_account --resource-group $resource_group --location $LOCATION --sku Standard_LRS
  fi
fi

cs=$(az storage account show-connection-string -g $actual_storage_rg -n $storage_account | jq -r .connectionString)
if ! az storage container exists --name $storage_container --connection-string "$cs" | jq -r .exists | grep -q true; then
  echo "Creating storage container $storage_container..."
  az storage container create --name $storage_container --connection-string "$cs"
fi

if ! az sig show --gallery-name $compute_gallery --resource-group $resource_group &>/dev/null; then
  echo "Creating compute gallery $compute_gallery..."
  az sig create --gallery-name $compute_gallery --resource-group $resource_group --location $LOCATION
fi

blob_name=$(basename "$image")
OVERWRITE_FLAG=""
if [ "$FORCE" = true ]; then
    OVERWRITE_FLAG="--overwrite"
fi

echo "Uploading blob $blob_name to container $storage_container..."
az storage blob upload --connection-string $cs -c $storage_container -f $image \
	-n $blob_name $OVERWRITE_FLAG

managed_image_name="${image_definition}-managed"
blob_uri="https://$storage_account.blob.core.windows.net/$storage_container/$blob_name"
if ! az image show -g $resource_group -n $managed_image_name &>/dev/null; then
  echo "Creating managed image $managed_image_name from VHD..."
  az image create -g $resource_group -n $managed_image_name \
    --source $blob_uri \
    --os-type Linux \
    --hyper-v-generation V2
fi

# Create image definition
# Use a unique SKU based on the image name to avoid conflicts
image_sku=$(echo "$image_definition" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-64)
if ! az sig image-definition show -g $resource_group -r $compute_gallery -i $image_definition &>/dev/null; then
  echo "Creating image definition $image_definition..."
  az sig image-definition create -g $resource_group -r $compute_gallery -i $image_definition \
    --publisher ${USER}-publisher --offer ${USER}-offer --sku "$image_sku" \
    --features SecurityType=ConfidentialVmSupported --os-type Linux --hyper-v-generation V2
fi

echo "Creating image version $image_version..."
# Get the resource group's location to ensure it's included in target regions
rg_location=$(az group show --name $resource_group --query location -o tsv)
# If the desired location is different from the resource group location, include both
if [ "$LOCATION" != "$rg_location" ]; then
  target_regions="$rg_location $LOCATION"
else
  target_regions="$LOCATION"
fi
az sig image-version create -g $resource_group -r $compute_gallery -i $image_definition -e $image_version \
  --managed-image /subscriptions/$AZURE_SUBSCRIPTION_ID/resourceGroups/$resource_group/providers/Microsoft.Compute/images/$managed_image_name \
  --replica-count 1 \
  --target-regions $target_regions

echo "IMAGE: /resourceGroups/$resource_group/providers/Microsoft.Compute/galleries/$compute_gallery/images/$image_definition/versions/$image_version"
