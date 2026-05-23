# ================================================================================
# Security Lists
# OCI security lists attach at the subnet level — all instances in a subnet
# share the same rules, unlike AWS security groups which are per-instance.
#
# Two-tier model mirrors the AWS design:
#   Public subnet  — accepts port 80 from the internet (load balancer)
#   Private subnet — accepts port 80 only from the public subnet CIDR
#                    (10.0.0.0/26), so instances are only reachable via the LB
# ================================================================================

# The load balancer is the sole public entry point. Port 80 is open to the
# world so that any browser can reach the application.
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "asg-public-sl"

  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "0.0.0.0/0"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Unrestricted egress lets the LB forward requests to backend instances
  # and receive health-check responses — the LB initiates these connections
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}

# Restricting inbound port 80 to the public subnet CIDR means only traffic
# that originated from the load balancer subnet can reach instances. An
# external IP cannot reach instances directly even if it knows their private
# addresses — the security list is the enforcement point.
resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.main.id
  display_name   = "asg-private-sl"

  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "10.0.0.0/26"
    stateless = false
    tcp_options {
      min = 80
      max = 80
    }
  }

  # Bastion service tunnels SSH from within OCI infrastructure — source is
  # the VCN CIDR rather than the public subnet only, as OCI routes bastion
  # traffic internally before it reaches the instance
  ingress_security_rules {
    protocol  = "6" # TCP
    source    = "10.0.0.0/24"
    stateless = false
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Unrestricted egress allows instances to reach yum repos and OCI APIs
  # through the NAT gateway — no specific destination needs to be whitelisted
  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
    stateless   = false
  }
}
