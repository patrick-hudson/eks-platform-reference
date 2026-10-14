locals {
  tags            = merge(var.tags, { environment = var.environment, "managed-by" = "terraform", project = "eks-platform-reference" })
  primary_nat_key = sort(keys(var.subnets))[0]
  nat_subnets     = var.single_nat_gateway ? { for k, v in var.subnets : k => v if k == local.primary_nat_key } : var.subnets
}
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = var.name })
}
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = var.name })
}
resource "aws_subnet" "public" {
  for_each                = var.subnets
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.availability_zone
  cidr_block              = each.value.public_cidr
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${var.name}-public-${each.key}", "kubernetes.io/role/elb" = "1" })
}
resource "aws_subnet" "private" {
  for_each          = var.subnets
  vpc_id            = aws_vpc.this.id
  availability_zone = each.value.availability_zone
  cidr_block        = each.value.private_cidr
  tags              = merge(local.tags, { Name = "${var.name}-private-${each.key}", "kubernetes.io/role/internal-elb" = "1" })
}
resource "aws_eip" "nat" {
  for_each = local.nat_subnets
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })
}
resource "aws_nat_gateway" "this" {
  for_each      = local.nat_subnets
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = merge(local.tags, { Name = "${var.name}-${each.key}" })
  depends_on    = [aws_internet_gateway.this]
}
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${var.name}-public" })
}
resource "aws_route" "public" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = var.internet_cidr
  gateway_id             = aws_internet_gateway.this.id
}
resource "aws_route_table_association" "public" {
  for_each       = var.subnets
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table" "private" {
  for_each = var.subnets
  vpc_id   = aws_vpc.this.id
  tags     = merge(local.tags, { Name = "${var.name}-private-${each.key}" })
}
resource "aws_route" "private" {
  for_each               = var.subnets
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = var.internet_cidr
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? local.primary_nat_key : each.key].id
}
resource "aws_route_table_association" "private" {
  for_each       = var.subnets
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}
