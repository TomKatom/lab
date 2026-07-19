# Non-sensitive outputs — feed the Phase 3 Ansible inventory.

output "vm_ip" {
  description = "Static internal IP address of the k3s-node VM (on vmbr1)."
  value       = local.lab.network.vm_ip_address
}

output "vm_id" {
  description = "Proxmox VM ID of the k3s-node VM."
  value       = proxmox_virtual_environment_vm.k3s.vm_id
}

output "vm_name" {
  description = "Name of the k3s-node VM."
  value       = proxmox_virtual_environment_vm.k3s.name
}

output "runner_ip" {
  description = "Static internal IP address of the ci-runner VM (on vmbr1)."
  value       = local.lab.network.runner_address
}

output "runner_id" {
  description = "Proxmox VM ID of the ci-runner VM."
  value       = proxmox_virtual_environment_vm.runner.vm_id
}

output "runner_name" {
  description = "Name of the ci-runner VM."
  value       = proxmox_virtual_environment_vm.runner.name
}

output "node_name" {
  description = "Proxmox node the VM and firewall rules are provisioned on."
  value       = var.node_name
}

output "vmbr1_cidr" {
  description = "CIDR of the internal bridge vmbr1 (also the VM's gateway)."
  value       = local.lab.network.vmbr1_host_address
}

output "restrict_management" {
  description = "Whether management ports (SSH/Proxmox API/k8s API) are currently restricted to management_sources. False until Phase 3 verifies WireGuard end-to-end."
  value       = var.restrict_management
}
