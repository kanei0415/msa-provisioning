resource "aws_eip" "nlb_eip" {
  for_each = local.AZs
  domain   = "vpc"
}

resource "aws_lb" "kt_cloud_nlb" {
  name               = "kt-cloud-nlb"
  internal           = true
  load_balancer_type = "network"

  enable_cross_zone_load_balancing = true

  security_groups = [aws_security_group.kt_cloud_vpc_nlb_sg.id]

  dynamic "subnet_mapping" {
    for_each = local.AZs
    content {
      subnet_id     = aws_subnet.public[subnet_mapping.value.az].id
      allocation_id = aws_eip.nlb_eip[subnet_mapping.value.az].id
    }
  }
}

resource "aws_lb_target_group" "kt_cloud_cluster_master_tg" {
  name        = "ktcloud-cluster-master-tg"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = aws_vpc.kt_cloud_vpc.id
  target_type = "instance"

  preserve_client_ip = false

  health_check {
    protocol            = "TCP"
    port                = "6443"
    interval            = 10
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "kt_cloud_nlb_cluster_master_listener" {
  load_balancer_arn = aws_lb.kt_cloud_nlb.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kt_cloud_cluster_master_tg.arn
  }
}

resource "aws_lb_target_group_attachment" "kt_cloud_nlb_cluster_master_attatch" {
  for_each         = { for k, v in local.nodes : k => v if v.role == "master" }
  target_group_arn = aws_lb_target_group.kt_cloud_cluster_master_tg.arn
  target_id        = aws_instance.kt_cloud_vpc_node[each.key].id
  port             = 6443
}
