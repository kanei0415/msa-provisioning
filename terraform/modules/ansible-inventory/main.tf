terraform {
  required_version = ">= 1.10.0"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# ============================================================
# Ansible inventory.ini を吐き出す
# ============================================================
# 旧構成: 静的な workers の IP もここで埋めていた。
# ASG 化したので workers の IP はインベントリには載せない。Ansible 側は
# 「master と bastion」だけ知っていれば運用上問題ない（worker は ASG UserData
# で自走 join するため Ansible は触らない）。

resource "local_file" "inventory" {
  filename        = var.output_path
  file_permission = "0644"

  content = templatefile("${path.module}/inventory.tftpl", {
    bastion_a_ip      = var.nodes["ap-northeast-2a-bastion"].public_ip
    bastion_b_ip      = var.nodes["ap-northeast-2b-bastion"].public_ip
    master_private_ip = var.nodes["ap-northeast-2a-master-01"].private_ip
    vpc_id            = var.vpc_id
    cluster_name      = var.cluster_name
    join_command_ssm  = var.kubeadm_join_command_ssm_name
    aws_region        = var.aws_region
  })
}
