resource "aws_efs_file_system" "kt_cloud_cluster_efs" {
  creation_token = "kt_cloud_cluster_efs"
}

resource "aws_efs_mount_target" "kt_cloud_cluster_efs_mount_target" {
  for_each = local.AZs

  file_system_id  = aws_efs_file_system.kt_cloud_cluster_efs.id
  subnet_id       = aws_subnet.private[each.value.az].id
  security_groups = [aws_security_group.kt_cloud_cluster_efs_sg.id]
}
