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
  type    = string
  default = "t3.large"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.nano"
}

variable "node_ami_id" {
  type    = string
  default = null
}
