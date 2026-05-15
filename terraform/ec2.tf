resource "aws_instance" "kt_cloud_vpc_node" {
  for_each = local.nodes

  ami           = local.node_ami
  instance_type = each.value.instance_type

  subnet_id                   = each.value.subnet == "public" ? aws_subnet.public[each.value.az].id : aws_subnet.private[each.value.az].id
  vpc_security_group_ids      = each.value.role == "bastion" ? [aws_security_group.kt_cloud_vpc_bastion_node_sg.id] : [aws_security_group.kt_cloud_vpc_cluster_node_sg.id]
  key_name                    = aws_key_pair.ktcloud_key_pair.key_name
  iam_instance_profile        = each.value.role == "bastion" ? null : aws_iam_instance_profile.ktcloud_cluster_node_profile.name
  source_dest_check           = each.value.role != "bastion"
  associate_public_ip_address = each.value.role == "bastion"

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${each.key}
    EOF

  root_block_device {
    volume_size = each.value.role == "bastion" ? 10 : 30
    volume_type = "gp3"
    encrypted   = true
  }
}

resource "aws_ebs_volume" "worker_ebs" {
  for_each          = { for k, v in local.nodes : k => v if can(v.ebs_size) }
  availability_zone = each.value.az
  size              = each.value.ebs_size
}

resource "aws_volume_attachment" "worker_ebs_attatchment" {
  for_each = aws_ebs_volume.worker_ebs

  device_name = "/dev/sdh"
  volume_id   = each.value.id
  instance_id = aws_instance.kt_cloud_vpc_node[each.key].id
}
