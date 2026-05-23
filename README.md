# OCI Instance Pools

This project demonstrates a minimal OCI Instance Pool deployment using Terraform. It provisions a fleet of Apache web servers behind a flexible Load Balancer, with each instance displaying its own metadata — private IP, instance OCID, availability domain, and shape — on a styled page.

![OCI diagram](oci-instance-pools.png)

Instances run on VM.Standard.A1.Flex (Ampere ARM, 1 OCPU, 4 GB RAM) in a private subnet and are never directly reachable from the internet. All inbound traffic flows through the Load Balancer. A NAT Gateway provides outbound internet access for package installation. CPU-based threshold policies drive automatic scale-out and scale-in between 1 and 6 instances.

This solution is ideal for understanding the fundamentals of OCI Instance Pools without the complexity of application-specific configuration. It uses no Packer, no custom image, and deploys in a single Terraform phase.

![ipool](ipool.png)

## Prerequisites

* [An OCI Account](https://cloud.oracle.com/)
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm)
* [Install Latest Terraform](https://developer.hashicorp.com/terraform/install)

If this is your first time watching our content, we recommend starting with this video: [OCI + Terraform: Easy Setup](https://youtu.be/BCMQo0CB9wk). It provides a step-by-step guide to properly configure Terraform and the OCI CLI.

---

## Download this Repository

```bash
git clone https://github.com/mamonaco1973/oci-instance-pool.git
cd oci-instance-pool
```

---

## Build the Code

Run [check_env](check_env.sh) to validate your environment, then run [apply](apply.sh) to provision the infrastructure.

```bash
./apply.sh
```

[apply.sh](apply.sh) runs `terraform init` and `terraform apply`, then automatically calls [validate.sh](validate.sh) to confirm the deployment is healthy.

---

### Build Results

When the deployment completes, the following resources are created:

- **Networking:**
  - A VCN (10.0.0.0/24) with a public subnet (10.0.0.0/26) and a private subnet (10.0.0.128/26)
  - Internet Gateway for load balancer inbound traffic
  - NAT Gateway in the VCN for instance outbound access
  - Separate route tables for public and private subnets

- **Security:**
  - Public security list: accepts port 80 from the internet
  - Private security list: accepts port 80 only from the public subnet CIDR (10.0.0.0/26)

- **Load Balancer:**
  - Internet-facing flexible Load Balancer in the public subnet (10–100 Mbps)
  - Backend set with HTTP health checks on `/`
  - HTTP listener forwarding to the backend set

- **Instance Pool:**
  - Instance Configuration: VM.Standard.A1.Flex (Ampere ARM, 1 OCPU, 4 GB), Oracle Linux 9, httpd with OCI IMDSv2 metadata page
  - Instance Pool: min 1, initial 3, max 6 — spread across AD-1 and AD-2
  - Scale-out rule: +1 instance when CPU > 60%
  - Scale-in rule: -1 instance when CPU < 60%
  - 300-second cool-down between scaling actions

---

### Scaling Policies

| Rule          | Condition | Cool-down | Action      |
|---------------|-----------|-----------|-------------|
| asg-scale-out | CPU > 60% | 300s      | +1 instance |

The 300-second cool-down (OCI minimum) prevents repeated scale-out events before load stabilizes.

---

### Validate the Deployment

[validate.sh](validate.sh) is called automatically by [apply.sh](apply.sh). It polls the load balancer until it returns HTTP 200, then samples 6 responses to confirm load balancing is working. Different IP addresses across requests confirm that traffic is being distributed across instances.

```
NOTE: Load balancer endpoint: http://xxx.xxx.xxx.xxx
NOTE: Waiting for HTTP 200 from load balancer...
NOTE: Load balancer returned HTTP 200
NOTE: Sampling load balancer responses...

  [1] 10.0.0.132
  [2] 10.0.0.197
  [3] 10.0.0.132
  [4] 10.0.0.197
  [5] 10.0.0.132
  [6] 10.0.0.197

=================================================================================
  Instance Pool — Deployment validated!
=================================================================================
  LB  : http://xxx.xxx.xxx.xxx
=================================================================================
```

---

### Clean Up Infrastructure

When you are finished testing, you can remove all provisioned resources with:

```bash
./destroy.sh
```

This will use Terraform to delete the VCN, subnets, NAT Gateway, Load Balancer, Instance Pool, Instance Configuration, security lists, autoscaling configuration, and all other infrastructure created by the project.
