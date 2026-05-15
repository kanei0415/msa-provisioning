variable "output_path" {
  type = string
}

variable "nodes" {
  type = map(object({
    private_ip = string
    public_ip  = string
  }))
}

variable "nlb_dns_name" {
  type = string
}

variable "vpc_id" {
  type = string
}
