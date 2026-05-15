resource "aws_vpc" "kt_cloud_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "kt_cloud_vpc_igw" {
  vpc_id = aws_vpc.kt_cloud_vpc.id
}
