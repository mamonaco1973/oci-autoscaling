# ================================================================================
# Bastion Service
# Free OCI managed bastion in the private subnet — provides SSH access to pool
# instances without exposing them to the internet. connect.sh creates a
# port-forwarding session and tunnels SSH through it.
# ================================================================================

resource "oci_bastion_bastion" "main" {
  bastion_type     = "STANDARD"
  compartment_id   = var.compartment_ocid
  # target_subnet_id scopes the bastion to the private subnet — sessions can
  # only target instances within this subnet
  target_subnet_id = oci_core_subnet.private.id
  name             = "asg-bastion"

  # Allow connections from any IP — access is controlled by session auth
  client_cidr_block_allow_list = ["0.0.0.0/0"]
}
