resource "aws_security_group" "kt_cloud_cluster_efs_sg" {
  name   = "kt_cloud_cluster_efs_sg"
  vpc_id = aws_vpc.kt_cloud_vpc.id

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.kt_cloud_vpc.cidr_block]
  }
}

resource "aws_security_group" "kt_cloud_vpc_cluster_node_sg" {
  name   = "kt_cloud_vpc_cluster_node_sg"
  vpc_id = aws_vpc.kt_cloud_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "kt_cloud_vpc_bastion_node_sg" {
  name   = "kt_cloud_vpc_bastion_node_sg"
  vpc_id = aws_vpc.kt_cloud_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.my_ip_cidr]
  }

  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [local.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
