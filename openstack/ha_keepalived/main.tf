provider "openstack" {
  cloud = terraform.workspace
}

locals {
  rules_all = [
    { description = "ICMP (Ping)", protocol = "icmp" },
    { description = "VRRP", protocol = "vrrp", remote_group_id = "@self" },
    { description = "SSH", protocol = "tcp", port = 22 },
  ]
  rules_egress_only = [
    { description = "TCP", protocol = "tcp" },
    { description = "UDP", protocol = "udp" },
  ]
  rules_ingress_only = []
  rules_ingress = concat(local.rules_all, local.rules_ingress_only)
  rules_egress  = concat(local.rules_all, local.rules_egress_only)
}

module "example_sg" {
  source             = "haxorof/security-group/openstack"
  name               = "example-ha-keepalived"
  description        = "Security group for HA keepalive example"
  ingress_rules_ipv4 = local.rules_ingress
  egress_rules_ipv4  = local.rules_egress
}

module "example_net" {
  source = "haxorof/network/openstack"
  name   = "example-ha-keepalived"
  router = {
    create = true
    name = "example-ha-keepalived"
    external_network_name = var.external_net
  }
  subnets = [
    { cidr = "192.168.1.0/24", ip_version = 4, router_id = "@self" },
  ]
}

resource "openstack_networking_port_v2" "example" {
  count              = var.nr_of_instances
  name               = "example"
  security_group_ids = ["${module.example_sg.security_group_id}"]
  network_id         = module.example_net.network_id
  admin_state_up     = "true"
  fixed_ip {
    subnet_id = module.example_net.subnets[0].id
  }
  allowed_address_pairs {
    ip_address = openstack_networking_port_v2.example_vip.all_fixed_ips[0]
  }
}

resource "openstack_networking_port_v2" "example_vip" {
  name           = "example-vip"
  network_id     = module.example_net.network_id
  admin_state_up = "true"
  fixed_ip {
    subnet_id = module.example_net.subnets[0].id
  }
}

resource "openstack_networking_floatingip_v2" "example" {
  count = var.nr_of_instances
  pool  = var.external_net
}

resource "openstack_networking_floatingip_associate_v2" "example_vip" {
  floating_ip = openstack_networking_floatingip_v2.example[0].address
  port_id     = openstack_networking_port_v2.example_vip.id
}

# Necesary for provisioning of all instances
resource "openstack_networking_floatingip_associate_v2" "example_bastion" {
  floating_ip = openstack_networking_floatingip_v2.example[1].address
  port_id     = openstack_networking_port_v2.example[0].id
}

data "openstack_compute_flavor_v2" "example" {
  name = var.flavor_name
}

resource "openstack_compute_keypair_v2" "example" {
  name = "example-ha-keepalived"
}

resource "openstack_compute_servergroup_v2" "example" {
  name     = "example-ha-keepalived"
  policies = ["soft-anti-affinity"]
}

resource "openstack_compute_instance_v2" "example" {
  count      = var.nr_of_instances
  name       = "example-ha-keepalived-${count.index + 1}"
  image_name = var.image_name
  flavor_id  = data.openstack_compute_flavor_v2.example.id
  key_pair   = openstack_compute_keypair_v2.example.name

  scheduler_hints {
    group = openstack_compute_servergroup_v2.example.id
  }

  network {
    port = element(openstack_networking_port_v2.example.*.id, count.index)
  }

}

data "template_file" "example" {
  count    = var.nr_of_instances
  template = <<-EOT
    vrrp_instance VRRP1 {
        interface eth0
        virtual_router_id 41
        priority ${count.index}
        advert_int 1
        authentication {
            auth_type PASS
            auth_pass 1066
        }
        virtual_ipaddress {
            ${openstack_networking_port_v2.example_vip.all_fixed_ips[0]}/24
        }
    }  
  EOT
}

resource "null_resource" "example" {
  count = var.nr_of_instances
  triggers = {
    access_ip = element(openstack_compute_instance_v2.example.*.access_ip_v4, count.index)
  }

  connection {
    type = "ssh"
    host = element(openstack_compute_instance_v2.example.*.access_ip_v4, count.index)
    user = var.ssh_user
    private_key = openstack_compute_keypair_v2.example.private_key
    bastion_host = openstack_networking_floatingip_associate_v2.example_bastion.floating_ip
    agent = false
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install -y keepalived"
    ]
  }

  provisioner "file" {
    content = element(data.template_file.example.*.rendered, count.index)
    destination = "/var/tmp/keepalived.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /var/tmp/keepalived.conf /etc/keepalived/keepalived.conf",
      "rm /var/tmp/keepalived.conf",
      "sudo systemctl enable keepalived",
      "sudo systemctl restart keepalived",
    ]
  }
}

resource "null_resource" "example_vip" {
  triggers = {
    instance_provisioners = join(",", null_resource.example.*.id)
    floating_ip = openstack_networking_floatingip_associate_v2.example_vip.floating_ip
  }

  connection {
    type = "ssh"
    host = null_resource.example_vip.triggers.floating_ip
    user = var.ssh_user
    private_key = openstack_compute_keypair_v2.example.private_key
    agent = false
  }

  provisioner "remote-exec" {
    inline = [
      "echo \"Successfully accessed host '$(hostname)' via Virtual IP (VIP)\"",
    ]
  }
}
