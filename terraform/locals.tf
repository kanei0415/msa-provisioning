locals {
  common_tags = {
    Project                                     = var.project
    ManagedBy                                   = "terraform"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  my_ip_cidr = "${chomp(data.http.my_ip.response_body)}/32"

  node_ami = coalesce(var.node_ami_id, data.aws_ami.amazon_linux_2023.id)

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

  nodes = {
    "ap-northeast-2a-master-01" = {
      az            = "ap-northeast-2a",
      role          = "master",
      instance_type = var.master_instance_type,
      subnet        = "private"
    }
    "ap-northeast-2a-master-02" = {
      az            = "ap-northeast-2a",
      role          = "master",
      instance_type = var.master_instance_type,
      subnet        = "private"
    }
    "ap-northeast-2a-worker-01" = {
      az            = "ap-northeast-2a",
      role          = "worker",
      instance_type = var.worker_instance_type,
      subnet        = "private",
      ebs_size      = 20
    }
    "ap-northeast-2b-master-01" = {
      az            = "ap-northeast-2b",
      role          = "master",
      instance_type = var.master_instance_type,
      subnet        = "private"
    }
    "ap-northeast-2b-worker-01" = {
      az            = "ap-northeast-2b",
      role          = "worker",
      instance_type = var.worker_instance_type,
      subnet        = "private",
      ebs_size      = 20
    }
    "ap-northeast-2b-worker-02" = {
      az            = "ap-northeast-2b",
      role          = "worker",
      instance_type = var.worker_instance_type,
      subnet        = "private",
      ebs_size      = 20
    }
    "ap-northeast-2a-bastion" = {
      az            = "ap-northeast-2a",
      role          = "bastion",
      instance_type = var.bastion_instance_type,
      subnet        = "public"
    }
    "ap-northeast-2b-bastion" = {
      az            = "ap-northeast-2b",
      role          = "bastion",
      instance_type = var.bastion_instance_type,
      subnet        = "public"
    }
  }
}
