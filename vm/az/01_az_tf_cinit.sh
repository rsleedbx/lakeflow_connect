#!/usr/bin/env bash
# Provision an Azure Ubuntu VM with Terraform; install Podman via cloud-init.
# Prototype parallel to vm/az/01_az_tf_ansible.sh. Must be sourced.

# error out when undeclared variable is used
set -u

# must be sourced for exports to continue
if [ "$0" == "$BASH_SOURCE" ]; then
  echo "Script is being executed directly. Please run as source $0"
  exit 1
fi

_LFC_REPO_ROOT="${_LFC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export _LFC_REPO_ROOT

_VM_AZ_DIR="${_LFC_REPO_ROOT}/vm/az"
_TF_DIR="${_VM_AZ_DIR}/terraform"
_CINIT_FILE="${_VM_AZ_DIR}/cloud-init/podman.yml"
_SSH_DIR="${_TF_DIR}/.ssh"
_CINIT_TFVARS_JSON="${_TF_DIR}/cloud_init.tfvars.json"

# #############################################################################
# Prereqs

for _bin in terraform az ssh jq; do
  if ! command -v "${_bin}" >/dev/null 2>&1; then
    echo "ERROR: required binary not found: ${_bin}" >&2
    return 1
  fi
done

if [[ ! -f "${_CINIT_FILE}" ]]; then
  echo "ERROR: cloud-init file not found: ${_CINIT_FILE}" >&2
  return 1
fi

# #############################################################################
# AZ Cloud

AZ_INIT

if [[ -z "${DB_HOST:-}" ]]; then
  DB_HOST="${DB_BASENAME}"
fi
export DB_HOST

# Admin username for the Linux VM (Azure disallows some names; fall back safely)
_VM_ADMIN="${DBA_USERNAME:-azureuser}"
# Azure reserved / invalid admin names — use azureuser if needed
case "${_VM_ADMIN}" in
  admin|root|administrator|guest|user)
    _VM_ADMIN="azureuser"
    ;;
esac

mkdir -p "${_SSH_DIR}"
_SSH_KEY_PATH="${_SSH_DIR}/id_rsa"

# Firewall CIDRs → HCL list (DB_FIREWALL_CIDRS may be string or bash array)
_cidrs_hcl="["
_first=1
if declare -p DB_FIREWALL_CIDRS 2>/dev/null | grep -q 'declare -a'; then
  for _c in "${DB_FIREWALL_CIDRS[@]}"; do
    [[ ${_first} -eq 1 ]] || _cidrs_hcl+=", "
    _cidrs_hcl+="\"${_c}\""
    _first=0
  done
else
  # space- or comma-separated string
  _IFS="${IFS}"
  IFS=$' ,\t\n'
  # shellcheck disable=SC2086
  for _c in ${DB_FIREWALL_CIDRS:-0.0.0.0/0}; do
    [[ -z "${_c}" ]] && continue
    [[ ${_first} -eq 1 ]] || _cidrs_hcl+=", "
    _cidrs_hcl+="\"${_c}\""
    _first=0
  done
  IFS="${_IFS}"
fi
_cidrs_hcl+="]"

# #############################################################################
# Write terraform.tfvars + cloud-init var file (jq for safe multiline)

echo -e "\nWriting ${_TF_DIR}/terraform.tfvars\n"

cat > "${_TF_DIR}/terraform.tfvars" <<EOF
resource_group_name  = "${RG_NAME}"
location             = "${CLOUD_LOCATION}"
vm_name              = "${DB_HOST}"
admin_username       = "${_VM_ADMIN}"
firewall_cidrs       = ${_cidrs_hcl}
owner                = "${DBX_USERNAME:-}"
remove_after         = "${REMOVE_AFTER:-}"
ssh_private_key_path = "${_SSH_KEY_PATH}"
EOF

echo -e "Writing ${_CINIT_TFVARS_JSON} from ${_CINIT_FILE}\n"
jq -n --rawfile cinit "${_CINIT_FILE}" '{cloud_init_user_data: $cinit}' > "${_CINIT_TFVARS_JSON}" || return 1

# #############################################################################
# Terraform apply

echo -e "\nTerraform init + apply (Azure VM + cloud-init)\n"
echo -e   "----------------------------------------------\n"

(
  cd "${_TF_DIR}" || exit 1
  terraform init -upgrade || exit 1
  terraform apply -auto-approve \
    -var-file=terraform.tfvars \
    -var-file=cloud_init.tfvars.json || exit 1
) || return 1

# Export VM_* from environment_variables output
eval "$(
  cd "${_TF_DIR}" && terraform output -json environment_variables \
    | jq -r 'to_entries[] | "export \(.key)=\(.value | @sh)"'
)" || return 1

echo "VM_NAME=${VM_NAME}"
echo "VM_HOST_FQDN=${VM_HOST_FQDN}"
echo "VM_PUBLIC_IP=${VM_PUBLIC_IP}"
echo "VM_ADMIN_USERNAME=${VM_ADMIN_USERNAME}"
echo "VM_SSH_PRIVATE_KEY=${VM_SSH_PRIVATE_KEY}"

# #############################################################################
# Wait for SSH

echo -e "\nWaiting for SSH on ${VM_HOST_FQDN}\n"

_ssh_ok=0
for _i in $(seq 1 36); do
  if ssh -i "${VM_SSH_PRIVATE_KEY}" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      -o BatchMode=yes \
      "${VM_ADMIN_USERNAME}@${VM_HOST_FQDN}" true 2>/dev/null; then
    _ssh_ok=1
    echo "SSH ready (attempt ${_i})"
    break
  fi
  echo "  SSH not ready yet (attempt ${_i}/36); sleeping 10s"
  sleep 10
done
if [[ "${_ssh_ok}" -ne 1 ]]; then
  echo "ERROR: SSH did not become ready on ${VM_HOST_FQDN}" >&2
  return 1
fi

# #############################################################################
# Wait for cloud-init + verify Podman

echo -e "\nWaiting for cloud-init (Podman install)\n"
echo -e   "-------------------------------------\n"

ssh -i "${VM_SSH_PRIVATE_KEY}" \
  -o StrictHostKeyChecking=accept-new \
  -o BatchMode=yes \
  "${VM_ADMIN_USERNAME}@${VM_HOST_FQDN}" \
  'sudo cloud-init status --wait' || return 1

echo -e "\nVerifying Podman\n"
_podman_ver="$(
  ssh -i "${VM_SSH_PRIVATE_KEY}" \
    -o StrictHostKeyChecking=accept-new \
    -o BatchMode=yes \
    "${VM_ADMIN_USERNAME}@${VM_HOST_FQDN}" \
    'podman --version'
)" || return 1
echo "${_podman_ver}"

echo -e "\nPodman install succeeded on ${VM_HOST_FQDN}"
echo "SSH: ssh -i ${VM_SSH_PRIVATE_KEY} ${VM_ADMIN_USERNAME}@${VM_HOST_FQDN}"
echo "Destroy later: (cd ${_TF_DIR} && terraform destroy -auto-approve -var-file=terraform.tfvars)"
echo -e "\nBilling ${RG_NAME}: https://portal.azure.com/#@${az_tenantDefaultDomain}/resource/subscriptions/${az_id}/resourceGroups/${RG_NAME}/costanalysis"
