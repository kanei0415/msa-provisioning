locals {
  common_tags = {
    Project                                     = var.project
    ManagedBy                                   = "terraform"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"

  # Packer 済 AMI を優先、無ければ AL2023（ただし AL2023 は kubelet 未導入なので
  # 実質 ami_force ビルド前のフォールバック扱い）
  node_ami = coalesce(
    var.node_ami_id,
    try(data.aws_ami.k8s_node[0].id, null),
    data.aws_ami.amazon_linux_2023.id,
  )

  AZs = {
    "ap-northeast-2a" = {
      az           = "ap-northeast-2a"
      public_cidr  = "10.0.1.0/24"
      private_cidr = "10.0.2.0/24"
    }
    "ap-northeast-2b" = {
      az           = "ap-northeast-2b"
      public_cidr  = "10.0.3.0/24"
      private_cidr = "10.0.4.0/24"
    }
  }

  # 静的に立てるノード = master 1 + bastion 1。
  # worker は aws_autoscaling_group (asg.tf) に移管したのでここからは除外。
  # bastion は AZ 2b に 1 台のみ。cluster-node-sg は VPC 全域から到達可能なので
  # 2a private の master へも 2b bastion 経由で SSH できる。
  nodes = {
    "ap-northeast-2a-master-01" = {
      az            = "ap-northeast-2a",
      role          = "master",
      instance_type = var.master_instance_type,
      subnet        = "private"
    }
    "ap-northeast-2b-bastion" = {
      az            = "ap-northeast-2b",
      role          = "bastion",
      instance_type = var.bastion_instance_type,
      subnet        = "public"
    }
  }
}
