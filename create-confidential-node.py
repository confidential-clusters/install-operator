#!/usr/bin/env python3
# SPDX-License-Identifier: MIT

"""Create one Azure confidential OpenShift worker from an installed operator."""

from __future__ import annotations

import argparse
import base64
import binascii
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from typing import Any, Callable, Optional, Tuple

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required; install it with: python3 -m pip install PyYAML")


MAPI_NAMESPACE = "openshift-machine-api"
MAPI_ROLE = "machineconfiguration.openshift.io/role"
MACHINESET_LABEL = "machine.openshift.io/cluster-api-machineset"
MACHINE_ROLE_LABEL = "machine.openshift.io/cluster-api-machine-role"
NODE_ROLE_PREFIX = "node-role.kubernetes.io/"

REGISTER_SERVER_SERVICE = "register-server"
REGISTER_SERVER_PORT = 8000
REGISTER_SERVER_RESOURCE = "ignition-clevis-pin-trustee"
ROOT_SECRET = "root-secret"

MCP_TIMEOUT_SECONDS = 60
USER_DATA_TIMEOUT_SECONDS = 120
MACHINESET_TIMEOUT_SECONDS = 900
POLL_INTERVAL_SECONDS = 5
DEFAULT_VM_SIZE = "Standard_DC2as_v5"


class ProvisionError(RuntimeError):
    """An actionable provisioning error."""


def run_oc(*args: str) -> str:
    command = ["oc", *args]
    try:
        result = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        raise ProvisionError(f"could not run oc: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ProvisionError(f"{' '.join(command)} failed: {detail}")
    return result.stdout


def get_json(
    resource: str,
    name: Optional[str] = None,
    *,
    namespace: Optional[str] = None,
    selector: Optional[str] = None,
) -> dict[str, Any]:
    args = ["get", resource]
    if name:
        args.append(name)
    if namespace:
        args.extend(["--namespace", namespace])
    if selector:
        args.extend(["--selector", selector])
    args.extend(["--output", "json"])
    try:
        return json.loads(run_oc(*args))
    except json.JSONDecodeError as error:
        raise ProvisionError(f"oc returned invalid JSON for {resource}") from error


def write_manifest(output_dir: Path, filename: str, manifest: dict[str, Any]) -> Path:
    path = output_dir / filename
    path.write_text(yaml.safe_dump(manifest, sort_keys=False), encoding="utf-8")
    path.chmod(0o600)
    print(f"Generated {path}")
    return path


def apply_manifest(path: Path) -> None:
    print(run_oc("apply", "--filename", str(path)).strip())


def wait_until(description: str, timeout_seconds: int, predicate: Callable[[], bool]) -> None:
    print(f"Waiting for {description} (up to {timeout_seconds}s)")
    deadline = time.monotonic() + timeout_seconds
    last_error: Optional[Exception] = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                print(f"Ready: {description}")
                return
            last_error = None
        except ProvisionError as error:
            last_error = error
        time.sleep(POLL_INTERVAL_SECONDS)
    suffix = f"; last error: {last_error}" if last_error else ""
    raise ProvisionError(f"timed out waiting for {description}{suffix}")


def machine_config(name: str, machineset_name: str, image: str) -> dict[str, Any]:
    return {
        "apiVersion": "machineconfiguration.openshift.io/v1",
        "kind": "MachineConfig",
        "metadata": {
            "name": name,
            "labels": {
                MAPI_ROLE: machineset_name,
                MACHINESET_LABEL: machineset_name,
            },
        },
        "spec": {"osImageURL": image},
    }


def machine_config_pool(machineset_name: str) -> dict[str, Any]:
    return {
        "apiVersion": "machineconfiguration.openshift.io/v1",
        "kind": "MachineConfigPool",
        "metadata": {"name": machineset_name},
        "spec": {
            "machineConfigSelector": {
                "matchExpressions": [{
                    "key": MAPI_ROLE,
                    "operator": "In",
                    "values": ["worker", machineset_name],
                }]
            },
            "nodeSelector": {
                "matchLabels": {f"{NODE_ROLE_PREFIX}{machineset_name}": ""}
            },
        },
    }


def mcp_contains_config(mcp_name: str, machine_config_name: str) -> bool:
    mcp = get_json("machineconfigpool", mcp_name)
    sources = mcp.get("status", {}).get("configuration", {}).get("source", [])
    return any(source.get("name") == machine_config_name for source in sources)


def mcp_is_updated(mcp_name: str) -> bool:
    mcp = get_json("machineconfigpool", mcp_name)
    conditions = mcp.get("status", {}).get("conditions", [])
    return any(
        condition.get("type") == "Updated" and condition.get("status") == "True"
        for condition in conditions
    )


def secret_exists(name: str) -> bool:
    get_json("secret", name, namespace=MAPI_NAMESPACE)
    return True


def percent_encode_non_alphanumeric(value: bytes) -> str:
    return "".join(
        chr(byte) if chr(byte).isascii() and chr(byte).isalnum() else f"%{byte:02X}"
        for byte in value
    )


def register_server_address(operator_namespace: str) -> str:
    service = get_json(
        "service", REGISTER_SERVER_SERVICE, namespace=operator_namespace
    )
    ingress = service.get("status", {}).get("loadBalancer", {}).get("ingress", [])
    if not ingress:
        raise ProvisionError(
            f"service {operator_namespace}/{REGISTER_SERVER_SERVICE} has no LoadBalancer "
            "ingress. The service must already be externally reachable by booting nodes; "
            "this script does not modify the installed operator or its Service."
        )
    host = ingress[0].get("hostname") or ingress[0].get("ip")
    if not host:
        raise ProvisionError(
            f"service {operator_namespace}/{REGISTER_SERVER_SERVICE} ingress has no hostname or IP"
        )
    return f"https://{host}:{REGISTER_SERVER_PORT}/{REGISTER_SERVER_RESOURCE}"


def root_ca(operator_namespace: str) -> bytes:
    root = get_json("secret", ROOT_SECRET, namespace=operator_namespace)
    encoded_ca = root.get("data", {}).get("ca.crt")
    if not encoded_ca:
        raise ProvisionError(
            f"secret {operator_namespace}/{ROOT_SECRET} has no data['ca.crt']"
        )
    try:
        return base64.b64decode(encoded_ca, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ProvisionError(
            f"secret {operator_namespace}/{ROOT_SECRET} has invalid ca.crt"
        ) from error


def extended_user_data_secret(
    existing_secret_name: str, register_address: str, ca_bytes: bytes
) -> Tuple[str, dict[str, Any]]:
    existing = get_json("secret", existing_secret_name, namespace=MAPI_NAMESPACE)
    encoded_user_data = existing.get("data", {}).get("userData")
    if not encoded_user_data:
        raise ProvisionError(
            f"secret {MAPI_NAMESPACE}/{existing_secret_name} has no data.userData"
        )
    try:
        ignition = json.loads(base64.b64decode(encoded_user_data, validate=True))
    except (ValueError, binascii.Error, json.JSONDecodeError) as error:
        raise ProvisionError(
            f"secret {MAPI_NAMESPACE}/{existing_secret_name} has invalid userData"
        ) from error

    try:
        merges = ignition["ignition"]["config"]["merge"]
        certificate_authorities = ignition["ignition"]["security"]["tls"][
            "certificateAuthorities"
        ]
    except (KeyError, TypeError) as error:
        raise ProvisionError(
            "MCO userData lacks ignition.config.merge or "
            "ignition.security.tls.certificateAuthorities"
        ) from error
    if not isinstance(merges, list) or not isinstance(certificate_authorities, list):
        raise ProvisionError("MCO userData has invalid Ignition merge or CA lists")

    ignition["ignition"]["version"] = "3.6.0"
    merges.append({"source": register_address})
    certificate_authorities.append(
        {"source": f"data:,{percent_encode_non_alphanumeric(ca_bytes)}"}
    )

    new_name = f"{existing_secret_name}-cocl"
    serialized = json.dumps(ignition, separators=(",", ":")).encode("utf-8")
    return new_name, {
        "apiVersion": "v1",
        "kind": "Secret",
        "metadata": {"name": new_name, "namespace": MAPI_NAMESPACE},
        "data": {"userData": base64.b64encode(serialized).decode("ascii")},
    }


def select_source_machineset(
    location: Optional[str] = None, zone: Optional[str] = None
) -> dict[str, Any]:
    result = get_json(
        "machinesets.machine.openshift.io",
        namespace=MAPI_NAMESPACE,
        selector=f"{MACHINE_ROLE_LABEL}=worker",
    )
    candidates = []
    available_placements = []
    for machineset in result.get("items", []):
        provider = (
            machineset.get("spec", {})
            .get("template", {})
            .get("spec", {})
            .get("providerSpec", {})
            .get("value", {})
        )
        if (
            isinstance(provider, dict)
            and provider.get("kind") == "AzureMachineProviderSpec"
            and isinstance(provider.get("osDisk"), dict)
        ):
            provider_location = str(provider.get("location", ""))
            provider_zone = str(provider.get("zone", ""))
            available_placements.append(
                f"{provider_location or '<unset>'}/zone-{provider_zone or '<unset>'}"
            )
            if location and provider_location.casefold() != location.casefold():
                continue
            if zone and provider_zone != zone:
                continue
            candidates.append(machineset)
    if not candidates:
        requested = "/".join(
            value for value in [location, f"zone-{zone}" if zone else None] if value
        )
        available = ", ".join(sorted(set(available_placements))) or "none"
        raise ProvisionError(
            f"no usable Azure worker MachineSet matches {requested or 'the request'}; "
            f"available placements: {available}"
        )
    candidates.sort(key=lambda item: item.get("metadata", {}).get("name", ""))
    selected = candidates[0]
    selected_provider = selected["spec"]["template"]["spec"]["providerSpec"]["value"]
    print(
        "Selected source MachineSet "
        f"{selected['metadata']['name']} "
        f"(location={selected_provider.get('location')}, zone={selected_provider.get('zone')})"
    )
    return selected


def adapted_machineset(
    source: dict[str, Any],
    machineset_name: str,
    user_data_secret: str,
    resource_id: str,
    vm_size: str = DEFAULT_VM_SIZE,
) -> dict[str, Any]:
    machineset = copy.deepcopy(source)
    source_name = machineset.get("metadata", {}).get("name", "<unknown>")
    machineset.pop("status", None)
    machineset["metadata"] = {
        "name": machineset_name,
        "namespace": MAPI_NAMESPACE,
    }

    spec = machineset.setdefault("spec", {})

    spec["replicas"] = 1
    selector_labels = spec.setdefault("selector", {}).setdefault("matchLabels", {})
    selector_labels[MACHINESET_LABEL] = machineset_name

    template = spec.setdefault("template", {})
    template_labels = template.setdefault("metadata", {}).setdefault("labels", {})
    template_labels[MACHINESET_LABEL] = machineset_name
    template_spec = template.setdefault("spec", {})
    machine_labels = template_spec.setdefault("metadata", {}).setdefault("labels", {})
    machine_labels[f"{NODE_ROLE_PREFIX}{machineset_name}"] = ""

    try:
        provider = template_spec["providerSpec"]["value"]
        if provider.get("kind") != "AzureMachineProviderSpec":
            raise ProvisionError(f"MachineSet {source_name} is not an Azure provider")
        os_disk = provider["osDisk"]
    except (KeyError, TypeError) as error:
        raise ProvisionError(
            f"MachineSet {source_name} has an incomplete Azure providerSpec"
        ) from error

    provider["image"] = {"resourceID": resource_id}
    provider["securityProfile"] = {
        "settings": {
            "confidentialVM": {
                "uefiSettings": {
                    "secureBoot": "Enabled",
                    "virtualizedTrustedPlatformModule": "Enabled",
                }
            },
            "securityType": "ConfidentialVM",
        }
    }
    managed_disk = os_disk.get("managedDisk")
    if not isinstance(managed_disk, dict):
        managed_disk = {}
        os_disk["managedDisk"] = managed_disk
    disk_security_profile = managed_disk.get("securityProfile")
    if not isinstance(disk_security_profile, dict):
        disk_security_profile = {}
        managed_disk["securityProfile"] = disk_security_profile
    disk_security_profile["securityEncryptionType"] = "VMGuestStateOnly"
    provider["vmSize"] = vm_size
    provider["acceleratedNetworking"] = False
    provider["userDataSecret"] = {"name": user_data_secret}
    print(f"Using source MachineSet {source_name}")
    return machineset


def machineset_has_ready_replica(name: str) -> bool:
    machineset = get_json(
        "machineset.machine.openshift.io", name, namespace=MAPI_NAMESPACE
    )
    return machineset.get("status", {}).get("readyReplicas", 0) == 1


def required_environment(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ProvisionError(f"required environment variable {name} is not set")
    return value


def provision(
    operator_namespace: str,
    location: Optional[str] = None,
    zone: Optional[str] = None,
    vm_size: str = DEFAULT_VM_SIZE,
) -> None:
    if not shutil.which("oc"):
        raise ProvisionError("oc was not found in PATH")

    approved_image = required_environment("APPROVED_IMAGE")
    azure_resource_id = required_environment("AZURE_RESOURCE_ID")
    get_json("namespace", operator_namespace)
    register_address = register_server_address(operator_namespace)
    ca_bytes = root_ca(operator_namespace)
    source = select_source_machineset(location, zone)

    machineset_name = f"worker-cvm-{operator_namespace}"
    if len(machineset_name) > 63:
        raise ProvisionError(
            f"generated resource name {machineset_name!r} exceeds 63 characters"
        )
    machine_config_name = f"99-{machineset_name}"
    output_dir = Path.cwd() / "create-confidential-node-manifests" / operator_namespace
    output_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    output_dir.chmod(0o700)
    print(f"Writing manifests to {output_dir}")

    mc_path = write_manifest(
        output_dir,
        "machineconfig.yaml",
        machine_config(machine_config_name, machineset_name, approved_image),
    )
    mcp_path = write_manifest(
        output_dir,
        "machineconfigpool.yaml",
        machine_config_pool(machineset_name),
    )
    apply_manifest(mc_path)
    apply_manifest(mcp_path)

    wait_until(
        f"MachineConfigPool {machineset_name} to include {machine_config_name}",
        MCP_TIMEOUT_SECONDS,
        lambda: mcp_contains_config(machineset_name, machine_config_name),
    )
    wait_until(
        f"MachineConfigPool {machineset_name} to report Updated=True",
        MCP_TIMEOUT_SECONDS,
        lambda: mcp_is_updated(machineset_name),
    )

    managed_secret_name = f"{machineset_name}-user-data-managed"
    wait_until(
        f"Secret {MAPI_NAMESPACE}/{managed_secret_name}",
        USER_DATA_TIMEOUT_SECONDS,
        lambda: secret_exists(managed_secret_name),
    )
    user_data_name, user_data = extended_user_data_secret(
        managed_secret_name, register_address, ca_bytes
    )
    secret_path = write_manifest(
        output_dir, "user-data-secret.yaml", user_data
    )
    apply_manifest(secret_path)

    machineset = adapted_machineset(
        source, machineset_name, user_data_name, azure_resource_id, vm_size
    )
    machineset_path = write_manifest(output_dir, "machineset.yaml", machineset)
    apply_manifest(machineset_path)

    wait_until(
        f"MachineSet {MAPI_NAMESPACE}/{machineset_name} to have one ready replica",
        MACHINESET_TIMEOUT_SECONDS,
        lambda: machineset_has_ready_replica(machineset_name),
    )
    print(f"Confidential node provisioning completed for MachineSet {machineset_name}")


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Provision one Azure confidential node using an operator that is already installed"
        )
    )
    parser.add_argument("namespace", help="namespace containing the installed operator")
    parser.add_argument(
        "--location",
        help="Azure location to select from the cluster's existing worker MachineSets",
    )
    parser.add_argument(
        "--zone",
        help="Azure availability zone to select from the existing worker MachineSets",
    )
    parser.add_argument(
        "--vm-size",
        default=DEFAULT_VM_SIZE,
        help=f"Azure VM size (default: {DEFAULT_VM_SIZE})",
    )
    args = parser.parse_args()
    try:
        provision(args.namespace, args.location, args.zone, args.vm_size)
    except ProvisionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
