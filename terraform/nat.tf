resource "aws_eip" "nat" {
  for_each = local.AZs
  domain   = "vpc"
}

resource "aws_nat_gateway" "kt_cloud_vpc_nat" {
  for_each      = local.AZs
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  depends_on    = [aws_internet_gateway.kt_cloud_vpc_igw]
}
