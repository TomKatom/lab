# ci-runner — a minimal self-hosted GitHub Actions runner VM. Tofu only
# provisions the shell: sizing, disk, network attachment, and the cloud-init
# identity/network config needed to SSH in the first time. A later Ansible
# `github_runner` role installs the toolchain and registers it with GitHub;
# no packages are installed at boot.
resource "proxmox_virtual_environment_vm" "runner" {
  name      = var.runner_vm_name
  node_name = var.node_name
  vm_id     = var.runner_vm_id

  agent {
    enabled = true
    # qemu-guest-agent isn't installed until Ansible provisions the guest, so
    # the provider's post-apply wait for its network-interfaces report can't
    # succeed yet. Keep the timeout short so plan/apply don't sit on the
    # default 15m wait every run until then.
    timeout = "15s"
  }

  cpu {
    cores = var.runner_vm_cores
    type  = var.vm_cpu_type
  }

  memory {
    dedicated = var.runner_vm_memory_mb
  }

  operating_system {
    type = "l26"
  }

  # scsi0 — OS disk, imported from the Debian 13 cloud image. Single disk
  # only: this is a CI runner, not a storage/compute node.
  disk {
    datastore_id = var.system_storage_pool
    import_from  = proxmox_download_file.debian13.id
    interface    = "scsi0"
    size         = var.runner_vm_disk_size_gb
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
        address = local.runner_ip_cidr
        gateway = local.vm_gateway
      }
    }

    dns {
      servers = var.vm_dns_servers
    }

    user_account {
      username = var.vm_username
      keys     = local.lab.admin_ssh_public_keys
    }
  }
}
