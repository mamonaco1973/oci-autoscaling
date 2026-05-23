#!/bin/bash
# ================================================================================
# connect.sh
# Opens an SSH session to a private pool instance via OCI Bastion.
# Usage: ./connect.sh [private-ip]
# If no IP is given, connects to the first RUNNING instance in the pool.
# ================================================================================

set -uo pipefail

LOCAL_PORT=2222

# ------------------------------------------------------------------------------
# Resolve bastion OCID from Terraform output
# ------------------------------------------------------------------------------

BASTION_ID=$(terraform -chdir=01-autoscaling output -raw bastion_id 2>/dev/null || true)
if [ -z "${BASTION_ID}" ]; then
  echo "ERROR: Could not read bastion_id from Terraform outputs. Run ./apply.sh first."
  exit 1
fi

# ------------------------------------------------------------------------------
# Resolve target IP — argument takes priority, otherwise pick first RUNNING instance
# ------------------------------------------------------------------------------

if [ -n "${1:-}" ]; then
  TARGET_IP="$1"
else
  if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
    OCI_COMPARTMENT_ID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
  fi

  TARGET_IP=$(oci compute instance list \
    --compartment-id "${OCI_COMPARTMENT_ID}" \
    --lifecycle-state RUNNING \
    --query 'data[0]."primary-private-ip-address"' \
    --raw-output 2>/dev/null || true)

  if [ -z "${TARGET_IP}" ] || [ "${TARGET_IP}" = "null" ]; then
    echo "ERROR: No RUNNING instances found. Check the instance pool status."
    exit 1
  fi
fi

echo "NOTE: Target instance IP: ${TARGET_IP}"

# ------------------------------------------------------------------------------
# Generate a temporary RSA key for the bastion session
# OCI Bastion rejects ECDSA keys — temp RSA avoids touching the Terraform key
# ------------------------------------------------------------------------------

TMP_DIR=$(mktemp -d /tmp/bastion_XXXXXX)
TMP_KEY="${TMP_DIR}/key"
ssh-keygen -t rsa -b 4096 -f "${TMP_KEY}" -N "" -q
chmod 600 "${TMP_KEY}"

cleanup() {
  rm -rf "${TMP_DIR}"
  kill "${TUNNEL_PID}" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Create port-forwarding bastion session
# ------------------------------------------------------------------------------

echo "NOTE: Creating bastion session..."

TARGET_DETAILS="{\"targetResourcePrivateIpAddress\": \"${TARGET_IP}\", \"targetResourcePort\": 22, \"sessionType\": \"PORT_FORWARDING\"}"

SESSION_JSON=$(oci bastion session create \
  --bastion-id "${BASTION_ID}" \
  --target-resource-details "${TARGET_DETAILS}" \
  --key-type PUB \
  --ssh-public-key-file "${TMP_KEY}.pub" \
  --session-ttl-in-seconds 10800)

SESSION_ID=$(echo "${SESSION_JSON}" | jq -r '.data.id')
echo "NOTE: Session: ${SESSION_ID}"
echo "NOTE: Waiting for ACTIVE..."

while true; do
  SESSION_DATA=$(oci bastion session get --session-id "${SESSION_ID}")
  STATE=$(echo "${SESSION_DATA}" | jq -r '.data["lifecycle-state"]')
  echo "  ${STATE}"
  [ "${STATE}" = "ACTIVE" ] && break
  sleep 10
done
# Brief settle time after ACTIVE before the tunnel is usable
sleep 5

# ------------------------------------------------------------------------------
# Open SSH tunnel then connect
# ------------------------------------------------------------------------------

TUNNEL_CMD=$(echo "${SESSION_DATA}" | jq -r '.data["ssh-metadata"].command' \
  | sed "s|<privateKey>|${TMP_KEY}|g" \
  | sed "s|<localPort>|${LOCAL_PORT}|g")

echo "NOTE: Opening tunnel on localhost:${LOCAL_PORT}..."
# Kill any stale listener on the port before binding
fuser -k "${LOCAL_PORT}/tcp" >/dev/null 2>&1 || true
sleep 1
eval "${TUNNEL_CMD} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" &
TUNNEL_PID=$!
sleep 3

ssh -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -i 01-autoscaling/keys/Private_Key \
  -p "${LOCAL_PORT}" \
  opc@localhost
