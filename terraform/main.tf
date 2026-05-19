module "ansible-inventory" {
  source      = "./modules/ansible-inventory"
  output_path = "${path.module}/../ansible/inventory.ini"
  nodes = {
    for name, instance in aws_instance.kt_cloud_vpc_node : name => {
      private_ip = instance.private_ip
      public_ip  = instance.public_ip
    }
  }
  vpc_id                        = aws_vpc.kt_cloud_vpc.id
  cluster_name                  = var.cluster_name
  kubeadm_join_command_ssm_name = aws_ssm_parameter.kubeadm_join_command.name
  aws_region                    = data.aws_region.current.id
}
