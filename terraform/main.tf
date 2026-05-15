module "ansible-inventory" {
  source      = "./modules/ansible-inventory"
  output_path = "/Users/kanei/Developer/msa-provisioning/ansible/inventory.ini"
  nodes = {
    for name, instance in aws_instance.kt_cloud_vpc_node : name => {
      private_ip = instance.private_ip
      public_ip  = instance.public_ip
    }
  }
  nlb_dns_name = aws_lb.kt_cloud_nlb.dns_name
  vpc_id       = aws_vpc.kt_cloud_vpc.id
}
