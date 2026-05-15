output "ap-northeast-2a-bastion-connect-command" {
  value = "ssh ec2-user@${aws_instance.kt_cloud_vpc_node["ap-northeast-2a-bastion"].public_ip} -i ~/.ssh/ktcloud-bastion-node-key"
}

output "ap-northeast-2b-bastion-connect-command" {
  value = "ssh ec2-user@${aws_instance.kt_cloud_vpc_node["ap-northeast-2b-bastion"].public_ip} -i ~/.ssh/ktcloud-bastion-node-key"
}

output "main-master-node-connect-command" {
  value = "ssh -A -J ec2-user@${aws_instance.kt_cloud_vpc_node["ap-northeast-2b-bastion"].public_ip} ec2-user@${aws_instance.kt_cloud_vpc_node["ap-northeast-2b-master-01"].private_ip}"
}
