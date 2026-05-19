variable "output_path" {
  type = string
}

variable "nodes" {
  type = map(object({
    private_ip = string
    public_ip  = string
  }))
}

variable "vpc_id" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "kubeadm_join_command_ssm_name" {
  type        = string
  description = "ASG 化により workers は Ansible から見えないので、join 用 SSM 名を Ansible 側にも伝えておく。"
}

variable "aws_region" {
  type = string
}
