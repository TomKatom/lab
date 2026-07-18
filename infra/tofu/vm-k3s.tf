# k3s-node — the VM k3s gets installed onto by Ansible (Phase 3). Tofu only
# provisions the shell: sizing, disks, network attachment, and the
# cloud-init identity/network config needed to SSH in the first time.
resource "proxmox_virtual_environment_vm" "k3s" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id

  agent {
    enabled = true
    # qemu-guest-agent isn't installed until Ansible (Phase 3) provisions the
    # guest, so the provider's post-apply wait for its network-interfaces
    # report can't succeed yet. Keep the timeout short so plan/apply don't
    # sit on the default 15m wait every run until then.
    timeout = "15s"
  }

  cpu {
    cores = var.vm_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.vm_memory_mb
  }

  operating_system {
    type = "l26"
  }

  # scsi0 — OS disk, imported from the Debian 13 cloud image.
  disk {
    datastore_id = var.system_storage_pool
    import_from  = proxmox_download_file.debian13.id
    interface    = "scsi0"
    size         = var.vm_disk_size_gb
  }

  # scsi1 — data disk, raw and blank (no import_from). Formatted and
  # mounted for local-path-provisioner by Ansible (Phase 3); Plex metadata
  # and the *arr DBs grow here.
  disk {
    datastore_id = var.data_storage_pool
    interface    = "scsi1"
    size         = var.vm_data_disk_size_gb
  }

  network_device {
    bridge = proxmox_network_linux_bridge.vmbr1.name
    model  = "virtio"
    # Required for the VM-scoped firewall (firewall.tf) to filter this vNIC.
    firewall = true
  }

  initialization {
    datastore_id = var.system_storage_pool

    ip_config {
      ipv4 {
        address = local.vm_ip_cidr
        gateway = local.vm_gateway
      }
    }

    dns {
      servers = var.vm_dns_servers
    }

    user_account {
      username = var.vm_username
      keys     = var.ssh_public_keys
    }
  }
}
