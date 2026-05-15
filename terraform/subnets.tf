resource "aws_subnet" "public" {
  for_each          = local.AZs
  vpc_id            = aws_vpc.kt_cloud_vpc.id
  cidr_block        = each.value.public_cidr
  availability_zone = each.value.az

  tags = {
    Name                     = "${var.project}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.AZs
  vpc_id            = aws_vpc.kt_cloud_vpc.id
  cidr_block        = each.value.private_cidr
  availability_zone = each.value.az

  tags = {
    Name                              = "${var.project}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.kt_cloud_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kt_cloud_vpc_igw.id
  }

  tags = {
    Name = "${var.project}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  for_each       = local.AZs
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  for_each = local.AZs
  vpc_id   = aws_vpc.kt_cloud_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.kt_cloud_vpc_nat[each.key].id
  }

  tags = {
    Name = "${var.project}-private-rt-${each.key}"
  }
}

resource "aws_route_table_association" "private" {
  for_each       = local.AZs
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}
