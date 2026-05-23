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
# Load Balancer — individual backend health
# ------------------------------------------------------------------------------

echo "================================================================================="
echo "  Load Balancer — Individual Backend Health"
echo "================================================================================="

oci lb backend list \
  --load-balancer-id "${LB_OCID}" \
  --backend-set-name "asg-backend-set" \
  --output table \
  --query 'data[*].{"Backend":name,"Drain":drain,"Offline":offline}' \
  2>/dev/null || echo "  Could not list backends."

# ------------------------------------------------------------------------------
# Load Balancer — backend set health status
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  Load Balancer — Backend Set Health Status"
echo "================================================================================="

oci lb backend-set-health get \
  --load-balancer-id "${LB_OCID}" \
  --backend-set-name "asg-backend-set" \
  --query 'data.status' \
  --raw-output 2>/dev/null || echo "  Could not retrieve."

# ------------------------------------------------------------------------------
# Instances — find asg-instances and show lifecycle state
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  Compute Instances — Lifecycle State"
echo "================================================================================="

oci compute instance list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --display-name "asg-instance" \
  --output table \
  --query 'data[*].{"State":\"lifecycle-state\","AD":\"availability-domain\","IP":\"primary-private-ip-address\","ID":id}' \
  2>/dev/null || echo "  Could not list instances."

# ------------------------------------------------------------------------------
# Console history — capture boot log from first running instance
# Captures cloud-init output including userdata.sh, which is the fastest
# way to see what failed on private instances without SSH access
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  Console History — First Running Instance"
echo "================================================================================="

INSTANCE_ID=$(oci compute instance list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --display-name "asg-instance" \
  --lifecycle-state RUNNING \
  --query 'data[0].id' \
  --raw-output 2>/dev/null || echo "")

if [ -z "${INSTANCE_ID}" ] || [ "${INSTANCE_ID}" = "null" ]; then
  echo "  No RUNNING instances found — instances may still be provisioning."
else
  echo "  Capturing console history for ${INSTANCE_ID}..."
  HISTORY_ID=$(oci compute console-history capture \
    --instance-id "${INSTANCE_ID}" \
    --query 'data.id' \
    --raw-output 2>/dev/null || echo "")

  if [ -z "${HISTORY_ID}" ]; then
    echo "  Could not capture console history."
  else
    # Wait for capture to complete
    for i in $(seq 1 12); do
      STATE=$(oci compute console-history get \
        --instance-console-history-id "${HISTORY_ID}" \
        --query 'data."lifecycle-state"' \
        --raw-output 2>/dev/null || echo "UNKNOWN")
      [ "${STATE}" = "SUCCEEDED" ] && break
      sleep 5
    done

    echo "  --- boot log (last 100 lines) ---"
    oci compute console-history get-content \
      --instance-console-history-id "${HISTORY_ID}" \
      --length 65536 \
      --file - 2>/dev/null | tail -100 || echo "  Could not retrieve console content."
  fi
fi

# ------------------------------------------------------------------------------
# HTTP probe
# ------------------------------------------------------------------------------

echo ""
echo "================================================================================="
echo "  HTTP Probe — http://${LB_IP}/plain"
echo "================================================================================="
HTTP_CODE=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 \
  "http://${LB_IP}/plain" 2>/dev/null || echo "000")
echo "  HTTP status: ${HTTP_CODE}"
echo ""
