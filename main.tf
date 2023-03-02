variable "account_id" {
  type = string
}

variable "assume_role" {
  type    = string
  default = ""
}

variable "region" {
  type = string
}

variable "name" {
  type    = string
  default = "terraform-ecs-demo"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "4.56.0"
    }
  }
}

provider "aws" {
  allowed_account_ids = [var.account_id]
  region              = var.region

  assume_role {
    role_arn     = var.assume_role
    session_name = "Terraform"
  }

  default_tags {
    tags = {
      Workspace = var.name
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  caller_identity = data.aws_caller_identity.current.arn
}

output "caller_identity" {
  value = local.caller_identity
}

locals {
  tags = {
    Name      = var.name
    Workspace = var.name
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.19.0"

  name = var.name
  cidr = "10.99.0.0/18"

  azs             = ["${var.region}a", "${var.region}b", "${var.region}c"]
  public_subnets  = ["10.99.0.0/24", "10.99.1.0/24", "10.99.2.0/24"]
  private_subnets = ["10.99.3.0/24", "10.99.4.0/24", "10.99.5.0/24"]

  enable_nat_gateway      = true
  single_nat_gateway      = true
  enable_dns_hostnames    = true
  map_public_ip_on_launch = false

  tags = local.tags
}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "4.17.1"

  name        = var.name
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  ingress_cidr_blocks = ["0.0.0.0/0"]
  ingress_rules       = ["https-443-tcp"]

  egress_rules = ["all-all"]

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/ecs/${var.name}"
  retention_in_days = 1

  tags = local.tags
}

## https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

locals {
  user_data = <<-EOT
    #!/bin/bash
    cat <<'EOF' >>/etc/ecs/ecs.config
    ECS_CLUSTER=${var.name}
    ECS_LOGLEVEL=debug
    EOF
  EOT
}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "6.7.1"

  name = var.name

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = var.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(local.user_data)
  ignore_desired_capacity_changes = true

  create_iam_instance_profile = true
  iam_role_name               = var.name
  iam_role_description        = "ECS role for ${var.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.private_subnets
  health_check_type   = "EC2"
  min_size            = 0
  max_size            = 2
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

  tags = local.tags
}

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "4.1.3"

  cluster_name = var.name

  cluster_configuration = {
    execute_command_configuration = {
      logging = "OVERRIDE"
      log_configuration = {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.this.name
      }
    }
  }

  autoscaling_capacity_providers = {
    this = {
      auto_scaling_group_arn         = module.autoscaling.autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 5
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }

      default_capacity_provider_strategy = {
        weight = 60
        base   = 20
      }
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "podinfo" {
  name              = "/aws/ecs/${var.name}/podinfo"
  retention_in_days = 1

  tags = local.tags
}

resource "aws_ecs_task_definition" "podinfo" {
  family = "podinfo"

  container_definitions = jsonencode(
    [
      {
        "name" : "podinfo",
        "image" : "stefanprodan/podinfo",
        "cpu" : 0,
        "memory" : 128,
        "logConfiguration" : {
          "logDriver" : "awslogs",
          "options" : {
            "awslogs-region" : "eu-west-1",
            "awslogs-group" : aws_cloudwatch_log_group.podinfo.name,
            "awslogs-stream-prefix" : "ec2"
          }
        }
      }
    ]
  )
}

resource "aws_ecs_service" "podinfo" {
  name            = "podinfo"
  cluster         = module.ecs.cluster_id
  task_definition = aws_ecs_task_definition.podinfo.arn

  desired_count = 1

  deployment_maximum_percent         = 100
  deployment_minimum_healthy_percent = 0
}
