# ============================================================
# 静的 EC2 — master + bastion のみ
# ============================================================
# worker は asg.tf の aws_autoscaling_group に移管。
# 旧来あった aws_ebs_volume / aws_volume_attachment は EBS CSI Driver で
# 動的プロビジョニングするため削除。

resource "aws_instance" "kt_cloud_vpc_node" {
  for_each = local.nodes

  ami           = each.value.role == "bastion" ? data.aws_ami.amazon_linux_2023.id : local.node_ami
  instance_type = each.value.instance_type

  subnet_id                   = each.value.subnet == "public" ? aws_subnet.public[each.value.az].id : aws_subnet.private[each.value.az].id
  vpc_security_group_ids      = each.value.role == "bastion" ? [aws_security_group.kt_cloud_vpc_bastion_node_sg.id] : [aws_security_group.kt_cloud_vpc_cluster_node_sg.id]
  key_name                    = aws_key_pair.ktcloud_key_pair.key_name
  iam_instance_profile        = each.value.role == "bastion" ? null : aws_iam_instance_profile.ktcloud_cluster_node_profile.name
  source_dest_check           = each.value.role != "bastion"
  associate_public_ip_address = each.value.role == "bastion"

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${each.key}
    EOF

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  tags = merge(local.common_tags, {
    Name = each.key
    Role = each.value.role
  })
}
