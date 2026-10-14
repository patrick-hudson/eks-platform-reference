output "vpc_id" {
  description = "VPC identifier."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnets in stable key order."
  value       = [for s in aws_subnet.public : s.id]
}

output "private_subnet_ids" {
  description = "Private subnets in stable key order."
  value       = [for s in aws_subnet.private : s.id]
}

output "nat_public_ips" {
  description = "Outbound IP addresses by availability zone."
  value       = { for k, e in aws_eip.nat : k => e.public_ip }
}
