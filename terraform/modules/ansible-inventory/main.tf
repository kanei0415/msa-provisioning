terraform {
  required_version = ">= 1.10.0"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "local_file" "inventory" {
  filename        = var.output_path
  file_permission = "0644"

  content = templatefile("${path.module}/inventory.tftpl", {
    bastion_a_ip = var.nodes["ap-northeast-2a-bastion"].public_ip
    bastion_b_ip = var.nodes["ap-northeast-2b-bastion"].public_ip

    ap-northeast-2a-master-node-01 = var.nodes["ap-northeast-2a-master-01"].private_ip
    ap-northeast-2a-master-node-02 = var.nodes["ap-northeast-2a-master-02"].private_ip
    ap-northeast-2a-worker-node-01 = var.nodes["ap-northeast-2a-worker-01"].private_ip
    ap-northeast-2b-master-node-01 = var.nodes["ap-northeast-2b-master-01"].private_ip
    ap-northeast-2b-worker-node-01 = var.nodes["ap-northeast-2b-worker-01"].private_ip
    ap-northeast-2b-worker-node-02 = var.nodes["ap-northeast-2b-worker-02"].private_ip

    ktcloud_nlb_dns_name = var.nlb_dns_name
    vpc_id               = var.vpc_id
  })
}
