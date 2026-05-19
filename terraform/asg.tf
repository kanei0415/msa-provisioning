# ============================================================
# worker ASG — Cluster Autoscaler 管理対象
# ============================================================
# 設計:
#   - AZ ごとに 1 つの ASG を作る (2a / 2b)。CA の標準パターンであり、
#     EBS で AZ をまたげない StatefulSet と相性が良い。
#   - 単一の Launch Template を 2 ASG で共有 (AMI / インスタンスタイプ / SG /
#     IAM / UserData が同一なため)。Subnet だけ ASG 側で差別化する。
#   - UserData は SSM から kubeadm join-command を取得して join する。
#   - CA が discover するための必須タグ:
#       k8s.io/cluster-autoscaler/enabled              = true
#       k8s.io/cluster-autoscaler/<cluster-name>       = owned
#   - scale-from-zero 用の node-template タグ (CA が起動前に label/taint を予測):
#       k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone = <az>
#       k8s.io/cluster-autoscaler/node-template/label/node.kubernetes.io/role     = worker
# ============================================================

# ------------------------------------------------------------
# Launch Template
# ------------------------------------------------------------
resource "aws_launch_template" "worker" {
  name_prefix = "${var.cluster_name}-worker-"
  description = "k8s worker node launch template (joins via SSM kubeadm-join-command)"

  image_id      = local.node_ami
  instance_type = var.worker_instance_type
  key_name      = aws_key_pair.ktcloud_key_pair.key_name

  vpc_security_group_ids = [aws_security_group.kt_cloud_vpc_cluster_node_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.ktcloud_worker_node_profile.name
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
    instance_metadata_tags      = "enabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.worker_root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/templates/worker-userdata.sh.tftpl", {
    cluster_name        = var.cluster_name
    aws_region          = data.aws_region.current.id
    join_command_ssm    = aws_ssm_parameter.kubeadm_join_command.name
    containerd_cri_sock = "unix:///var/run/containerd/containerd.sock"
    master_private_ip   = aws_instance.kt_cloud_vpc_node["ap-northeast-2a-master-01"].private_ip
  }))

  # AWS Auto Scaling rejects tag keys containing `/` when launching instances
  # via a Launch Template, even though EC2 RunInstances itself accepts them.
  # → ここでは `/` を含まないタグだけを置き、`kubernetes.io/cluster/<name>=owned`
  #   は worker UserData が自分で ec2:CreateTags で付ける。
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.cluster_name}-worker"
      Role      = "worker"
      Project   = var.project
      ManagedBy = "terraform"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name      = "${var.cluster_name}-worker-root"
      Project   = var.project
      ManagedBy = "terraform"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------
# ASG (per AZ)
# ------------------------------------------------------------
resource "aws_autoscaling_group" "workers" {
  for_each = local.AZs

  name             = "${var.cluster_name}-workers-${each.value.az}"
  min_size         = var.worker_asg_min_per_az
  max_size         = var.worker_asg_max_per_az
  desired_capacity = var.worker_asg_desired_per_az

  vpc_zone_identifier = [aws_subnet.private[each.key].id]

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # ASG が回す capacity を Terraform が監視・修正しない。
  # CA が動的に伸縮させるので desired を terraform が上書きすると喧嘩する。
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # ------------------------------------------------------------
  # Cluster Autoscaler 用タグ
  # ------------------------------------------------------------
  # CA は AWS API で以下の 2 タグを持つ ASG を自動 discover する。
  # propagate_at_launch=false: タグはノードに伝播させない（ASG 側だけで OK）。
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }

  # ------------------------------------------------------------
  # scale-from-zero 用 node-template タグ
  # ------------------------------------------------------------
  # CA は ASG が 0 台の時に scale-up 判定するため、起動前のノードが
  # どんな label/taint を持つかを「ASG タグ」から推測する。
  tag {
    key                 = "k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone"
    value               = each.value.az
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/node-template/label/node.kubernetes.io/role"
    value               = "worker"
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/node-template/label/kubernetes.io/arch"
    value               = "amd64"
    propagate_at_launch = false
  }

  # ------------------------------------------------------------
  # 識別タグ (ASG 自体のみ。EC2 instance への適用は Launch Template の
  # tag_specifications で行う。両方で同じ key を立てると ASG → EC2 launch 時に
  # tag conflict で `is not a valid tag key` という誤解しやすいエラーが出る。)
  # ------------------------------------------------------------
  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-workers-${each.value.az}"
    propagate_at_launch = false
  }

  tag {
    key                 = "Project"
    value               = var.project
    propagate_at_launch = false
  }

  tag {
    key                 = "ManagedBy"
    value               = "terraform"
    propagate_at_launch = false
  }

  depends_on = [
    aws_ssm_parameter.kubeadm_join_command,
    aws_iam_instance_profile.ktcloud_worker_node_profile,
  ]
}

# ------------------------------------------------------------
# Outputs
# ------------------------------------------------------------
output "worker_asg_names" {
  description = "Cluster Autoscaler に渡す ASG 名一覧（per AZ）"
  value       = [for k, asg in aws_autoscaling_group.workers : asg.name]
}

output "worker_launch_template_id" {
  value = aws_launch_template.worker.id
}
