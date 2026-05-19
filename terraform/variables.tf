variable "project" {
  type    = string
  default = "kt-cloud"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "availability_zones" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "cluster_name" {
  type    = string
  default = "kt-cloud-cluster"
}

variable "master_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "worker_instance_type" {
  type        = string
  default     = "t3.large"
  description = "worker ASG の Launch Template 既定インスタンスタイプ。Mixed Instance Policy の override で他タイプも追加可能。"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.nano"
}

variable "node_ami_id" {
  type        = string
  default     = null
  description = "明示的に使う AMI ID。null の場合は Packer ビルド済 (tag:Role=k8s-node) を最新でルックアップする。"
}

# ------------------------------------------------------------
# worker ASG (Cluster Autoscaler 管理対象) のサイジング
# ------------------------------------------------------------
variable "worker_asg_min_per_az" {
  type        = number
  default     = 1
  description = "AZ あたり worker ASG の最小台数。最低 1 にしておけば CoreDNS / アプリ Pod が常に Schedulable。"
}

variable "worker_asg_max_per_az" {
  type        = number
  default     = 5
  description = "AZ あたり worker ASG の最大台数。CA がここまでしか scale-up しない。"
}

variable "worker_asg_desired_per_az" {
  type        = number
  default     = 2
  description = "AZ あたり worker ASG の初期 desired_capacity。初回 apply 時に立てる台数。"
}

variable "worker_root_volume_size" {
  type        = number
  default     = 30
  description = "worker ノードの root EBS サイズ (GB)。Packer AMI は 30GB で焼くため同等以上を推奨。"
}
