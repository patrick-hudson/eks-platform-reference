variable "environment" {
  description = "Environment used for resource tags and naming."
  type        = string
}

variable "tags" {
  description = "Additional resource tags; required ownership tags take precedence."
  type        = map(string)
  default     = {}
}

variable "name" {
  description = "Prefix for network resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "IPv4 CIDR for the VPC."
  type        = string
}

variable "subnets" {
  description = "One public and one private subnet per named availability zone."
  type        = map(object({ availability_zone = string, public_cidr = string, private_cidr = string }))
}

variable "single_nat_gateway" {
  description = "Use one shared NAT gateway instead of one in each availability zone."
  type        = bool
}

variable "internet_cidr" {
  description = "Destination CIDR for internet routes."
  type        = string
}
