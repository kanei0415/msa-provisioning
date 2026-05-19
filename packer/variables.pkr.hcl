variable "aws_region" {
  type        = string
  default     = "ap-northeast-2"
  description = "AMI をビルドする region。Terraform 側と一致させること。"
}

variable "project" {
  type    = string
  default = "kt-cloud"
}

variable "cluster_name" {
  type    = string
  default = "kt-cloud-cluster"
}

variable "ami_name_prefix" {
  type        = string
  default     = "kt-cloud-cluster-k8s-node"
  description = "完成 AMI の name prefix。実際の名前にはタイムスタンプを後ろに付ける。"
}

variable "kubernetes_version" {
  type        = string
  default     = "1.30"
  description = "kubelet / kubeadm / kubectl の minor バージョン (X.Y)。group_vars/all.yaml と揃える。"
}

variable "builder_instance_type" {
  type        = string
  default     = "t3.medium"
  description = "ビルド用 EC2 のサイズ。yum/dnf を回せる程度で十分。"
}

# ------------------------------------------------------------
# ビルダー EC2 を起動するサブネット
# ------------------------------------------------------------
# - 明示指定 (var.builder_subnet_id): その subnet を使う
# - 未指定:                            subnet_filter で「auto-assign public IP が true な
#                                       任意のサブネット」を探す。default VPC のサブネットが
#                                       消滅している環境では `make ami-prep` で復元する。
variable "builder_subnet_id" {
  type        = string
  default     = null
  description = "Packer がビルダー EC2 を起動する subnet ID。未指定なら `map-public-ip-on-launch=true` な subnet を自動検索。"
}
