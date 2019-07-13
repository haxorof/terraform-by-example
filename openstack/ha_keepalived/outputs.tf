output "ssh_private_key" {
  value = openstack_compute_keypair_v2.example.private_key
}

output "ssh_public_key" {
  value = openstack_compute_keypair_v2.example.public_key
}

output "vip_address" {
  value = openstack_networking_floatingip_associate_v2.example_vip.floating_ip
}