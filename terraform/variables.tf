variable "region" {
  description = "AWS region for the lab"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster and prefix for related resources"
  type        = string
  default     = "sre-lab"
}

variable "environment" {
  description = "Environment tag applied to all resources"
  type        = string
  default     = "lab"
}

variable "dns_zone_name" {
  description = "Existing Route 53 public hosted zone the lab apps are created under -- set this in terraform.tfvars (see terraform.tfvars.example), no default since it's specific to whoever is standing up the lab"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the lab VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_a" {
  description = "First availability zone used for subnets"
  type        = string
  default     = "us-east-1a"
}

variable "availability_zone_b" {
  description = "Second availability zone used for subnets"
  type        = string
  default     = "us-east-1b"
}

variable "public_subnet_a_cidr" {
  type    = string
  default = "10.0.0.0/24"
}

variable "public_subnet_b_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "private_subnet_a_cidr" {
  type    = string
  default = "10.0.10.0/24"
}

variable "private_subnet_b_cidr" {
  type    = string
  default = "10.0.11.0/24"
}

variable "kubernetes_version" {
  description = "EKS control plane version"
  type        = string
  default     = "1.33"
}

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group"
  type        = string
  default     = "t3.medium"
}

variable "node_group_desired_size" {
  type    = number
  default = 3
}

variable "node_group_min_size" {
  type    = number
  default = 2
}

variable "node_group_max_size" {
  type    = number
  default = 5
}

variable "db_instance_class" {
  description = "RDS instance class for the shared Postgres instance"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "Postgres engine version for the shared RDS instance"
  type        = string
  default     = "17.6"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_master_username" {
  description = "Master username for the shared RDS instance. Per-app databases and users are created on top of this at setup time."
  type        = string
  default     = "labadmin"
}

variable "acm_certificate_arn" {
  description = "ARN of an existing ISSUED ACM certificate covering *.<dns_zone_name>. scripts/setup.sh resolves (or requests) one and passes it in via TF_VAR_acm_certificate_arn; left empty, acm.tf looks one up by domain instead. The lab never creates or deletes certificates -- see the comment in acm.tf for why."
  type        = string
  default     = ""
}
