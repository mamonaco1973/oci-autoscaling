#!/bin/bash
set -euo pipefail

# Resolve compartment
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
fi

LB_OCID=$(terraform -chdir=01-autoscaling output -raw lb_ocid 2>/dev/null || true)
LB_IP=$(terraform -chdir=01-autoscaling output -raw lb_public_ip 2>/dev/null || true)

if [ -z "${LB_OCID}" ]; then
  echo "ERROR: Could not read Terraform outputs. Run ./apply.sh first."
  exit 1
fi

# ------------------------------------------------------------------------------
# Instance Pool — instance states
# ------------------------------------------------------------------------------

echo "================================================================================="
echo "  Instance Pool — Instance States"
echo "================================================================================="

POOL_ID=$(oci compute-management instance-pool list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --display-name "asg-pool" \
  --output text \
  --query 'data[0].id' 2>/dev/null || echo "")

if [ -z "${POOL_ID}" ]; then
  echo "  ERROR: Could not find instance pool 'asg-pool'."
else
  oci compute-management instance-pool-instance list \
    --compartment-id "${OCI_COMPARTMENT_ID}" \
    --instance-pool-id "${POOL_ID}" \
    --output table \
    --query 'data[*].{"State":\"lifecycle-state\","AD":\"availability-domain\","IP":\"private-ip\","ID":id}' 2>/dev/null || \
    echo "  Could not list pool instances."
fi

# ------------------------------------------------------------------------------
# Load Balancer — backend set health summary
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  Load Balancer — Backend Set Health"
echo "================================================================================="

oci lb backend-set-health get \
  --load-balancer-id "${LB_OCID}" \
  --backend-set-name "asg-backend-set" \
  --output table \
  --query 'data.{"Status":status,"OK":\"ok-state-backend-names\","Warning":\"warning-state-backend-names\","Critical":\"critical-state-backend-names\","Unknown":\"unknown-state-backend-names\"}' \
  2>/dev/null || echo "  Could not retrieve backend set health."

# ------------------------------------------------------------------------------
# Load Balancer — individual backend health
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  Load Balancer — Individual Backend Health"
echo "================================================================================="

oci lb backend list \
  --load-balancer-id "${LB_OCID}" \
  --backend-set-name "asg-backend-set" \
  --output table \
  --query 'data[*].{"Backend":name,"Drain":drain,"Offline":offline,"Backup":backup}' \
  2>/dev/null || echo "  Could not list backends."

# ------------------------------------------------------------------------------
# Quick HTTP probe — direct LB check
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  HTTP Probe — http://${LB_IP}/plain"
echo "================================================================================="

HTTP_CODE=$(curl -o /dev/null -sf -w "%{http_code}" --max-time 5 \
  "http://${LB_IP}/plain" 2>/dev/null || echo "000")
echo "  HTTP status: ${HTTP_CODE}"

echo ""
