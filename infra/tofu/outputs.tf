# Non-sensitive outputs — feed the Phase 3 Ansible inventory.

output "vm_ip" {
  description = "Static internal IP address of the k3s-node VM (on vmbr1)."
  value       = var.vm_ip_address
}

output "vm_id" {
  description = "Proxmox VM ID of the k3s-node VM."
  value       = proxmox_virtual_environment_vm.k3s.vm_id
}

output "vm_name" {
  description = "Name of the k3s-node VM."
  value       = proxmox_virtual_environment_vm.k3s.name
}

output "node_name" {
  description = "Proxmox node the VM and firewall rules are provisioned on."
  value       = var.node_name
}

output "vmbr1_cidr" {
  description = "CIDR of the internal bridge vmbr1 (also the VM's gateway)."
  value       = var.vmbr1_host_address
}

output "restrict_management" {
  description = "Whether management ports (SSH/Proxmox API/k8s API) are currently restricted to management_sources. False until Phase 3 verifies WireGuard end-to-end."
  value       = var.restrict_management
}
