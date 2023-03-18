#  AWS Terraform for Single Containers 

I recently worked through and wrote up a basic comparison of cloud providers, with the intent of juxtaposing the process for a Terraform-based workflow to new colleagues. I would run each provider, using Terraform, through a basic set of steps like account signup for tokens; provider initialization for Terraform; single-container deployment; deployment of a Kubernetes cluster; and finally taking down any resources.

This went fairly well for the usual suspects (Azure, DigitalOcean, and others) until I ran into AWS, where it proved to be much more complicated (despite the well-celebrated Elastic Container Services) to get a single container up and running. Most research pointed towards the use of third-party libraries which (while official) seemed to obfuscate a lot of the complexity required to get a working configuration within a single Terraform file.

It took some additional research, reverse-engineering, and (relatively fruitless) conversation with ChatGPT, but I'm pleased to present the following for your pleasure: a single-file, single-container deployment to AWS using Terraform.

## Accounts and Tokens

The first step is to sign up for an account. There are some limited free-credit offers available that should be enough to get you through this exercise. You will also need an API token for Terraform to authenticate with. AWS will get mad if you try and attach these to your root account--which, in all fairness, is a pretty significant security consideration. If you do decide to create a "service principal" or machine account for Terraform, you will need to use the IAM dashboard to attach the following privileges to the relevant user group:

* ec2 ("AmazonEC2FullAccess")

* ecs ("AmazonECS_FullAccess")

* elb ("ElasticLoadBalancingFullAccess")

* vpc ("AmazonVPCFullAcces")

With either approach, you will need to create/attach tokens to your user under "security credentials". The access key ID and secret values can be set to your environmental variables "AWS_ACCESS_KEY_ID" and "AWS_SECRET_ACCESS_KEY", respectively, where Terraform's AWS provider will automatically discover them. I prefer this method over committing them to file (even if separate from your main `.TF` content) because you never know when your `.gitignore` is going to miss, and it's fairly agnostic across providers.

## Providers and initialization

With that set up, you're good to create your `main.tf` file and start defining provider data. I also like to cache key parameters as local data near the top in case some tweaks and/or experimentation are called for. We also declare a procedural reference to availability zones with a `data` block, which makes for elegant lookup later on.

```tf
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
```

With this saved, you can run `terraform init` from your command shell to get Terraform warmed up for deploying resources.

## Virtual Private Cloud

The first set of resources we are going to define are for your VPC. You can think of this as a set of high-level network configurations that define the context in which traffic will be managed.

```tf
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
```

We have used a `aws_internet_gateway` here to identify the specific ingress point for our services network, and since we are just using a basic `nginx` container for this demonstration, we restrict the security group (which will be used later by our load balancer) to HTTP traffic on port 80.

You may also notice we are using the `count` meta-property. This involves some Terraform black magic that, once you wrap your head around it, is incredibly useful. The fundamental problem this addresses is the AWS requirement to deploy across multiple availability zones. (Recall that AWS availability zones are effectively unique data centers within the same region.) Therefore, we will need to define two virtual networks behind our ingress gateway. In the above code, this is reflected by the need to two elastic IP address ranges. More on this concept later.

## Public Networking

The load balancer will be responsible for routing traffic to either of the two availability zones. Because we are responsible cloud engineers, we will place our services within their own private network. After the load balancer, but before the private network, we must define a *public* network for routing to the NATs that will translate traffic across this division.

```tf
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
```

First, we define a route table for accepting universal traffic through our internet gateway (it's a minimal `nginx` image, we aren't going to be picky.) Then, we define a pair of subnets (one for each availability zone) for the public side of the translation. Once we define a NAT gateway to prepare for mapping from the public routes, we associate the (single) public route table across the pair of subnets.

The NAT element here is a critical component of the translation between public and private networks. Now that these are defined, we can cite them in our *private* route table later on, after which point the translation is complete.

## Load Balancing

With our public network defined, we can now set up a load balancer and related elements. Specifically, we will need a target group to define where load balancer traffic will be directed, and a listener that ties that group to the load balancer itself.

```tf
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
```

Some key elements to note here: First, the AWS provider will occasionally complain about stickiness if it isn't defined for the target group explicitly (even if disabled). Second, there are many types of load balancer approaches for different use cases. Because the load balancer is making decisions about modifying traffic routing, it will need to be part of the security group we defined earlier for ingress/egress routes. This is an *application* load balancer; for other use cases, see the (always excellent) Terraform documentation for the AWS provider:

  [https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb)

## Private Networking

With our ingress route defined, we can now start defining our private subnet. Our objective here is, for each availability zone, to define a subnet across a suitable (non-overlapping) range of addresses, with their own internal routing table, that will not be accessible from the "outside" (public internet).

```tf
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
```

Note, unlike the public networking (which ingested from a single route table for the internet gateway before splitting across availability zones), every element in the private network is replicated. We use some very handy tricks with `count.index`, to define everything from which NAT gateway to associate with to which range of addresses to include in our private subnet.

This is a good time to talk about classless inter-domain routing, or CIDR:

  [https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing](https://en.wikipedia.org/wiki/Classless_Inter-Domain_Routing)

You will typically see CIDR used to define a range of addresses by combining a traditional dotted-quad ("10.0.0.0") with a subnet mask in the form of a number following a trailing slash. This number defines the length of the mask used to fix bytes from the *beginning* of the address. So, the bigger this number is, the bigger the mask, and the fewer addresses included in the range.

When we defined our CIDR block for our public network, we used the following expression:

```tf
  cidr_block                          = "10.0.10${count.index + 1}.0/24"
```

In other words, since we are using two replicas (as defined by `local.availability_replicas`), our public subnets will have a block of "10.0.101.0/24" and "10.0.102.0/24". In contrast, our private subnet used the following CIDR block expression:

```tf
  cidr_block                          = "10.0.${count.index + 1}.0/24"
```

This means our private subnets will have blocks of "10.0.1.0/24" and "10.0.2.0/24", respectively. Non-overlapping CIDR blocks for address allocation using built-in procedural expressions within Terraform! Told you it was neat.

## Elastic Containers

Finally, we're ready to define our container deployment! This starts with a cluster, which (in AWS land) is basically an abstract set of resources. We also need to define "capacity providers" that will satisfy the needs (or tasks) that cluster will execute. Here's the full set of ECS resources:

```tf
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
```

Note that we've encoded a Fargate assumption into our local variables. This can be easily changed to EC2 or Fargate Spot approaches, though there may be some side effects on your resource specifications and deployment patterns.

If you're coming from a Kubernetes or Docker-Compose background, what you're most likely interested in is the `container_definitions` block within our task definition. AWS encapsulates a lot of elements that we don't typically think about being separate. (This is probably already obvious if you've made it this far!) In this case, a "task" is something our cluster's service should do. Since we want it to host a web server (nginx container). this is where we define how that container will be deployed.

Once we've defined the cluster & capacity providers, and identified our container deployment, we can tie everything together in the service our cluster will run. (This is roughly analogous to a "service" in the Kubernetes sense.) We tell AWS that the service will run on our specific cluster, with only one replica, with the given task definition. We also need to define associations to the load balancer and target group, as well as attaching it to our private network configuration.

## At Last

Eighteen resources later (not including replicas!), we've finally done it.

If you're like me, you may prefer to run `terraform plan` and `terraform apply` with each resource you add. This gives you a good incremental feeling for how resources are related together, and how "heavy" (e.g., startup time) they are. But if you haven't yet, now's the time:

```sh
$ terraform plan
...
$ terraform apply
```

With any luck, everything will deploy successfully! But you still don't know how to "get" (browse) into your service to see your precious `nginx` container. I find it is a big help to attach an output (in this case, from the load balancer DNS name) to report the final address you can plug into your browser. At the end of your Terraform file, add the following before you run `terraform plan` and `terraform apply` one last time.

```tf
output "url" {
  value = "http://${aws_lb.this.dns_name}"
}
```

Browse to that address, and you should see the basic `nginx` welcome page!

## Some Conclusions

Before I forget, the first thing you'll want to do is destroy your resources so Jeff Bezos doesn't take any more of your hard-earned money. Fortunately, we're using Terraform, so that's trivial:

```sh
$ terraform destroy
```

I've also uploaded this article to dev.to, if you just want to read through a more polished writeup:

  [https://dev.to/tythos/aws-terraform-for-single-containers-5dkf](https://dev.to/tythos/aws-terraform-for-single-containers-5dkf)

More to the point, though, a conclusion to our experiment. Why was this so painful? Similar activities in Azure or DigitalOcean will take one, maybe two, resources and will deploy at the drop of a hat. What's so special about AWS?

I've concluded that there are two reasons. The first is what I call "first mover disadvantage". There's no doubt AWS is the first and (to this day) biggest cloud provider in the commercial market. Along with defining the territory comes a risk of a) failing to streamline processes for developers across a variety of skill levels and backgrounds (not everyone is a network specialist or IT security professional!), and b) defining paradigms that made sense at first but soon became out of date or automated as new or better standards emerged and evolved.

The second reason is one that was nicely summarized by ChatGPT when I asked this question, although it wasn't a surprise:

![Image description](https://dev-to-uploads.s3.amazonaws.com/uploads/articles/cn6x3i6zdxrodibttayu.png)

And that's as good an observation as any.
