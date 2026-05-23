#!/bin/bash
# ================================================================================
# File: validate.sh
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Step 1: Resolve LB IP and OCID from Terraform output
# ------------------------------------------------------------------------------

LB_IP=$(terraform -chdir=01-autoscaling output -raw lb_public_ip 2>/dev/null || true)
LB_OCID=$(terraform -chdir=01-autoscaling output -raw lb_ocid 2>/dev/null || true)

if [ -z "${LB_IP}" ]; then
  echo "ERROR: Could not read Terraform outputs. Run ./apply.sh first."
  exit 1
fi

echo "NOTE: Load balancer endpoint: http://${LB_IP}"

# ------------------------------------------------------------------------------
# Step 2: Wait for healthy backends in asg-backend-set
# OCI LB provisioning + instance pool startup can take several minutes —
# poll every 15s until the backend set reports OK status
# ------------------------------------------------------------------------------

echo "NOTE: Waiting for healthy backends in asg-backend-set..."

# Resolve compartment for OCI CLI calls
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
fi

TIMEOUT=600
ELAPSED=0

while true; do
  STATUS=$(oci lb backend-set-health get \
    --load-balancer-id "${LB_OCID}" \
    --backend-set-name "asg-backend-set" \
    --output text \
    --query 'data.status' 2>/dev/null || echo "UNKNOWN")

  if [ "${STATUS}" = "OK" ]; then
    echo "NOTE: Backend set status: OK"
    break
  fi

  if [ "${ELAPSED}" -ge "${TIMEOUT}" ]; then
    echo "ERROR: Timed out waiting for healthy backends after ${TIMEOUT}s."
    exit 1
  fi

  echo "NOTE: Backend set status: ${STATUS} — retrying in 30s (${ELAPSED}s elapsed)..."
  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

# ------------------------------------------------------------------------------
# Step 3: Sample load balancer responses
# Hit the endpoint 6 times — different private IPs confirm load balancing works
# ------------------------------------------------------------------------------

echo "NOTE: Sampling load balancer responses..."
echo ""

for i in $(seq 1 6); do
  RESPONSE=$(curl -sf "http://${LB_IP}/plain")
  echo "  [${i}] ${RESPONSE}"
done

echo ""
echo "================================================================================="
echo "  Instance Pool — Deployment validated!"
echo "================================================================================="
echo "  LB  : http://${LB_IP}"
echo "================================================================================="
