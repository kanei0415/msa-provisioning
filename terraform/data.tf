data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# ------------------------------------------------------------
# Packer でビルド済の k8s-node AMI ルックアップ
# ------------------------------------------------------------
# Packer 側 (packer/packer.pkr.hcl) が AMI に付ける tag:
#   Project=kt-cloud, Role=k8s-node, ClusterName=kt-cloud-cluster, BuiltBy=packer
# tag マッチの最新を引く。AMI が無い場合は `make ami` 未実行なので apply は失敗する想定
# （var.node_ami_id を明示渡しでオーバーライド可能）。
data "aws_ami" "k8s_node" {
  count       = var.node_ami_id == null ? 1 : 0
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Role"
    values = ["k8s-node"]
  }

  filter {
    name   = "tag:ClusterName"
    values = [var.cluster_name]
  }

  filter {
    name   = "tag:BuiltBy"
    values = ["packer"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

data "http" "my_ip" {
  url = "https://ifconfig.me/ip"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
