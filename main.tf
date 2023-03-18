# note: running "terraform apply" from shell requires the following credential env vars:
# * AWS_ACCESS_KEY_ID
# * AWS_SECRET_ACCESS_KEY

terraform {
  required_version = ">= 0.13"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.56"
    }
  }
}

locals {
  project               = "aws-tf-single"
  container_name        = "nginx"
  container_port        = 80
  region                = "us-west-2"
  capacity_provider     = "FARGATE"
  availability_replicas = 2
}

provider "aws" {
  region = local.region
}

data "aws_availability_zones" "this" {
  state = "available"
}

### --- VPC

resource "aws_vpc" "this" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_security_group" "this" {
  vpc_id      = aws_vpc.this.id
  name_prefix = "-"

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP web traffic"
    from_port   = local.container_port
    to_port     = local.container_port
    protocol    = "tcp"
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}

resource "aws_eip" "these" { # we will need one IP range for each NAT
  count                = local.availability_replicas
  network_border_group = local.region
  public_ipv4_pool     = "amazon"
  vpc                  = true
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
}

### --- PUBLIC

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_subnet" "public" {
  count                               = local.availability_replicas
  cidr_block                          = "10.0.10${count.index + 1}.0/24"
  vpc_id                              = aws_vpc.this.id
  availability_zone                   = data.aws_availability_zones.this.names[count.index]
  map_public_ip_on_launch             = true
  private_dns_hostname_type_on_launch = "ip-name"
}

resource "aws_nat_gateway" "this" { # one NAT is required for mapping to each private route table
  count         = local.availability_replicas
  allocation_id = aws_eip.these[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}

resource "aws_route_table_association" "public" { # associate the public route table with each subnet
  count          = local.availability_replicas
  route_table_id = aws_route_table.public.id
  subnet_id      = aws_subnet.public[count.index].id
}

### --- ALB

resource "aws_lb_target_group" "this" {
  target_type     = "ip"
  port            = local.container_port
  protocol        = "HTTP"
  vpc_id          = aws_vpc.this.id
  ip_address_type = "ipv4"

  health_check {
    healthy_threshold   = 5
    matcher             = "200"
    path                = "/"
    timeout             = 5
    unhealthy_threshold = 2
  }

  stickiness {
    enabled = false
    type    = "lb_cookie"
  }
}

resource "aws_lb" "this" {
  ip_address_type    = "ipv4"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id

  security_groups = [
    aws_security_group.this.id,
    aws_vpc.this.default_security_group_id
  ]
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = local.container_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.id
  }
}

### --- PRIVATE

resource "aws_subnet" "private" {
  count                               = local.availability_replicas
  cidr_block                          = "10.0.${count.index + 1}.0/24"
  vpc_id                              = aws_vpc.this.id
  availability_zone                   = data.aws_availability_zones.this.names[count.index]
  private_dns_hostname_type_on_launch = "ip-name"
}

resource "aws_route_table" "private" {
  count  = local.availability_replicas
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }
}

resource "aws_route_table_association" "private" {
  count          = local.availability_replicas
  route_table_id = aws_route_table.private[count.index].id
  subnet_id      = aws_subnet.private[count.index].id
}

### --- ECS

resource "aws_ecs_cluster" "this" {
  name = "${local.project}-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = [local.capacity_provider]
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${local.project}-tasks"
  cpu                      = 256
  memory                   = 512
  network_mode             = "awsvpc"
  requires_compatibilities = [local.capacity_provider]

  container_definitions = jsonencode([{
    essential = true
    image     = "${local.container_name}:latest"
    name      = local.container_name
    portMappings = [{
      containerPort = local.container_port
      hostPort      = local.container_port
    }]
  }])
}

resource "aws_ecs_service" "this" {
  cluster         = aws_ecs_cluster.this.id
  desired_count   = 1
  launch_type     = local.capacity_provider
  name            = "${local.project}-service"
  task_definition = aws_ecs_task_definition.this.arn

  lifecycle {
    ignore_changes = [desired_count]
  }

  load_balancer {
    container_name   = local.container_name
    container_port   = local.container_port
    target_group_arn = aws_lb_target_group.this.arn
  }

  network_configuration {
    subnets = aws_subnet.private[*].id
  }
}

output "url" {
  value = "http://${aws_lb.this.dns_name}"
}
