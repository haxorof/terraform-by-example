provider "openstack" {
  cloud = terraform.workspace
}

terraform {
  required_version = ">= 0.12"
}

################################################################################
# Security group and rules
################################################################################
# --->

locals {
  rules_all = [
    { description = "ICMP (Ping)", protocol = "icmp" },
    { description = "SSH", protocol = "tcp", port = 22 },
  ]
  rules_egress_only = [
    { description = "HTTP", protocol = "tcp", port = 80 },
    { description = "HTTPS", protocol = "tcp", port = 443 },
    { description = "DNS", protocol = "tcp", port = 53 },
    { description = "DNS", protocol = "udp", port = 53 },
    { description = "Metadata Service", remote_ip_prefix = "169.254.169.254/32" },
    { description = "NTP", protocol = "udp", port = 123 },
  ]
  rules_ingress_only = []
  rules_ingress      = concat(local.rules_all, local.rules_ingress_only)
  rules_egress       = concat(local.rules_all, local.rules_egress_only)
}

module "example_sg" {
  source             = "haxorof/security-group/openstack"
  name               = "example-bastion-host"
  description        = "Security group for bastion host example"
  ingress_rules_ipv4 = local.rules_ingress
  egress_rules_ipv4  = local.rules_egress
}
# <---

################################################################################
# Network and subnets
################################################################################
# --->
module "example_net" {
  source = "haxorof/network/openstack"
  name   = "example-bastion-host"
  router = {
    create                = true
    name                  = "example-bastion-host"
    external_network_name = var.external_net
  }
  subnets = [
    { cidr = "192.168.1.0/24", router_id = "@self" },
  ]
}
# <---

################################################################################
# Ports and OpenStack floating IP
################################################################################
# --->
resource "openstack_networking_port_v2" "example" {
  name               = "example-bastion-host"
  security_group_ids = ["${module.example_sg.security_group_id}"]
  network_id         = module.example_net.network_id
  admin_state_up     = "true"
  fixed_ip {
    subnet_id = module.example_net.subnets[0].id
  }
}

resource "openstack_networking_floatingip_v2" "example" {
  pool = var.external_net
}

resource "openstack_networking_floatingip_associate_v2" "example" {
  floating_ip = openstack_networking_floatingip_v2.example.address
  port_id     = openstack_networking_port_v2.example.id
}
# <---

################################################################################
# Compute and related resources
################################################################################
# --->
data "openstack_compute_flavor_v2" "example" {
  name = var.flavor_name
}

resource "openstack_compute_keypair_v2" "example" {
  name       = "example-bastion-host"
  public_key = "${var.ssh_public_key}"
}

resource "openstack_compute_instance_v2" "example" {
  name         = "example-bastion-host"
  image_name   = var.image_name
  flavor_id    = data.openstack_compute_flavor_v2.example.id
  key_pair     = openstack_compute_keypair_v2.example.name
  config_drive = true

  network {
    port = openstack_networking_port_v2.example.id
  }

  connection {
    type  = "ssh"
    host  = openstack_networking_floatingip_associate_v2.example.floating_ip
    user  = var.ssh_user
    agent = true
  }

  # Ensures that the instance is created and accessable before null_resource is triggered
  provisioner "remote-exec" {
    inline = [
      "echo \"Successfully accessed host '$(hostname)'!\"",
    ]
  }

}
# <---

################################################################################
# Provisioning of compute instance
################################################################################
# --->
resource "local_file" "example_ansible_inventory" {
  content = <<-EOT
    bastion   ansible_host=${openstack_networking_floatingip_associate_v2.example.floating_ip}  ansible_user=${var.ssh_user}  ansible_ssh_common_args='-o StrictHostKeyChecking=no'
    EOT
  filename = "${path.module}/generated_inventory"
}

resource "null_resource" "example" {
  depends_on = [
    "openstack_compute_instance_v2.example",
    "local_file.example_ansible_inventory",
  ]

  provisioner "local-exec" {
    command = "ansible-galaxy install --force -r files/requirements.yml"
  }

  provisioner "local-exec" {
    command = "ansible-playbook -i generated_inventory files/playbook.yml"
  }
}
# <---
