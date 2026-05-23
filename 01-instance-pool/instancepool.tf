# ================================================================================
# Instance Pool
# The pool maintains the desired number of instances across multiple ADs,
# automatically replacing unhealthy instances. Placement configurations spread
# instances across AD-1 and AD-2 so the application stays available if one
# AD has an outage. The pool is registered directly with the load balancer
# backend set — new instances are added to rotation as they pass health checks,
# and removed when terminated during a scale-in event.
# ================================================================================

resource "oci_core_instance_pool" "main" {
  compartment_id            = var.compartment_ocid
  instance_configuration_id = oci_core_instance_configuration.main.id
  display_name              = "asg-pool"

  # Floor of 1 keeps the pool alive at minimum cost during quiet periods;
  # ceiling of 6 caps cost during a runaway load event. The autoscaling
  # config takes control of pool size after it is attached — ignore_changes
  # prevents Terraform from fighting autoscaling over the size attribute.
  size = 4

  lifecycle {
    ignore_changes = [size]
  }

  # Spread instances across AD-1 and AD-2 — pool distributes evenly across
  # the two placement configurations on each scale-out event
  placement_configurations {
    availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
    primary_subnet_id   = oci_core_subnet.private.id
  }

  placement_configurations {
    availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
    primary_subnet_id   = oci_core_subnet.private.id
  }

  # Registering with the backend set lets the LB route traffic to new instances
  # as soon as they pass health checks, and stop routing to them when they are
  # terminated during a scale-in event
  load_balancers {
    load_balancer_id = oci_load_balancer_load_balancer.main.id
    backend_set_name = oci_load_balancer_backend_set.main.name
    port             = 80
    vnic_selection   = "PrimaryVnic"
  }
}

# ================================================================================
# Autoscaling Configuration
# CPU utilization drives all scaling decisions. OCI threshold policies fire
# when the metric crosses the threshold — the cool-down period prevents rapid
# repeated actions before load stabilizes.
#
# Unlike AWS (separate CloudWatch alarms with configurable evaluation periods),
# OCI threshold policies react immediately when the threshold is crossed. The
# 300s cool-down fills the same protective role: it prevents scale-in during
# short quiet periods and scale-out storms on sudden load spikes.
#
# | Rule         | Condition   | Action      |
# |--------------|-------------|-------------|
# | asg-scale-out| CPU > 60%   | +1 instance |
# ================================================================================

resource "oci_autoscaling_auto_scaling_configuration" "main" {
  compartment_id = var.compartment_ocid
  display_name   = "asg-autoscaling"
  is_enabled     = true

  # 300s is the OCI minimum — prevents the pool from scaling again before the
  # previous batch of instances has absorbed or shed the load
  cool_down_in_seconds = 300

  auto_scaling_resources {
    id   = oci_core_instance_pool.main.id
    type = "instancePool"
  }

  policies {
    display_name = "asg-cpu-policy"
    policy_type  = "threshold"

    capacity {
      initial = 4
      min     = 2
      max     = 6
    }

    # OCI requires both a scale-out and scale-in rule — you cannot omit either.
    # Threshold is set to 1% so it never fires in practice (idle instances sit
    # at ~2-3% CPU due to system processes). For production, raise this to 10%
    # and ensure it stays well below the scale-out threshold to avoid oscillation.
    rules {
      display_name = "asg-scale-in"
      action {
        type  = "CHANGE_COUNT_BY"
        value = -1
      }
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "LT"
          value    = 1
        }
      }
    }

    # Scale-out: +1 instance when average CPU exceeds 60%
    rules {
      display_name = "asg-scale-out"
      action {
        type  = "CHANGE_COUNT_BY"
        value = 1
      }
      metric {
        metric_type = "CPU_UTILIZATION"
        threshold {
          operator = "GT"
          value    = 60
        }
      }
    }

  }
}
