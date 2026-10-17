# SPDX-License-Identifier: Apache-2.0

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "= 1.1.7"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "= 1.1.6"
    }
  }
}

variable "profile_id" {
  type = string
}

variable "base_image" {
  type = string
}

variable "base_checksum" {
  type = string
}

variable "qemu_binary" {
  type = string
}

variable "output_directory" {
  type = string
}

variable "image_name" {
  type = string
}

variable "disk_size" {
  type = string
}

variable "disk_format" {
  type = string
}

variable "builder_cpus" {
  type = number
}

variable "builder_memory" {
  type = number
}

variable "ssh_username" {
  type = string
}

variable "accelerator" {
  type = string
}

variable "machine_type" {
  type = string
}

variable "cpu_model" {
  type = string
}

variable "ansible_playbook" {
  type = string
}

variable "ansible_command" {
  type = string
}

variable "ansible_tmp_dir" {
  type = string
}

variable "ansible_variables" {
  type = any
}

source "qemu" "base_image" {
  accelerator             = var.accelerator
  boot_wait                = "15s"
  cpus                     = var.builder_cpus
  memory                   = var.builder_memory
  cd_content = {
    "meta-data" = "instance-id: iid-cosim-${var.profile_id}\n"
    "user-data" = "#cloud-config\nssh_authorized_keys:\n  - {{ .SSHPublicKey }}\n"
  }
  cd_label                 = "cidata"
  disk_image               = true
  disk_size                = var.disk_size
  format                   = var.disk_format
  headless                 = true
  iso_checksum             = "sha256:${var.base_checksum}"
  iso_url                  = var.base_image
  machine_type             = var.machine_type
  output_directory         = var.output_directory
  qemu_binary              = var.qemu_binary
  qemuargs                 = [["-cpu", var.cpu_model], ["-display", "none"]]
  shutdown_command         = "sudo shutdown -P now"
  shutdown_timeout         = "10m"
  skip_compaction          = true
  ssh_clear_authorized_keys = true
  ssh_handshake_attempts   = 100
  ssh_timeout              = "45m"
  ssh_username             = var.ssh_username
  use_backing_file         = false
  vm_name                  = var.image_name
}

build {
  sources = ["source.qemu.base_image"]

  provisioner "ansible" {
    command         = var.ansible_command
    playbook_file   = var.ansible_playbook
    user            = var.ssh_username
    use_proxy       = true
    ansible_env_vars = ["ANSIBLE_LOCAL_TEMP=${var.ansible_tmp_dir}"]
    extra_arguments = ["--extra-vars", jsonencode(var.ansible_variables)]
  }
}
