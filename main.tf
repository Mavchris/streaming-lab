provider "aws" { region = "eu-west-3" }

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = { Name = "streaming_lab_vpc" }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# 1. creation Sous-réseau public et privéé
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]
  tags                    = { Name = "streaming_public_subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "streaming_private_subnet" }
}

resource "aws_subnet" "alb1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "alb1_subnet" }
  availability_zone       = data.aws_availability_zones.available.names[1]
}

resource "aws_subnet" "alb2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.4.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "alb2_subnet" }
  availability_zone       = data.aws_availability_zones.available.names[2]
}


# 2. Passerelle Internet
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "streaming-lab-gateway" }

}
# 3. Table de routage pointant vers l'IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"

    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "streaming-lab-public-route" }

}

# 4. Table de routage privée
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "streaming-lab-private-route" }

}


# 5. Association des sous-réseaux à la table de routage
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "alb1" {
  subnet_id      = aws_subnet.alb1.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "alb2" {
  subnet_id      = aws_subnet.alb2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}


#mise en place des security groups

#1 security group load-balancer
resource "aws_security_group" "alb_sg" {

  name   = "application_load_balancer-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "https public vers le load balancer"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "streaming-lab-load_balancer" }

}

#2 security group frontend
resource "aws_security_group" "frontend_sg" {

  name   = "frontend-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "trafic entrant depuis le load balancer"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  ingress {
    description     = "trafic entrant depuis le load balancer"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }


  ingress {
    description     = "ingestion des flux video depuis le serveur de streaming tier2 uniquement"
    from_port       = 1935
    to_port         = 1935
    protocol        = "tcp"
    security_groups = [aws_security_group.streaming_sg.id]
  }

  ingress {
    description     = "connection admin via EICE"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "streaming-lab-frontend-pages" }

}

#3 security group streaming 
resource "aws_security_group" "streaming_sg" {

  name   = "sever_streaming-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "connection admin via EICE"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice_sg.id]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "streaming-lab-streaming" }
}

#4 security group database tier3
resource "aws_security_group" "database_sg" {

  name   = "database-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL depuis le Tier 1 uniquement"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.frontend_sg.id]
  }

  ingress {
    description     = "connection admin via EICE"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.eice_sg.id]
  }


  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "streaming-lab-database" }
}

#5 security group ec2 instance connection endpoint 
resource "aws_security_group" "eice_sg" {

  name   = "instance_connection-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "instance-connection-endpoint-lab-streaming" }
}

#6. creation d'une instance de connection EC2 pour la l'administration et la maintenance de mes instances
resource "aws_ec2_instance_connect_endpoint" "admin" {
  subnet_id          = aws_subnet.private.id
  security_group_ids = [aws_security_group.eice_sg.id]

  tags = { Name = "streaming-lab-ice" }

}



#creation des instance pour les 3 tiers

#A instance frontend
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  key_name               = "streaming-key"
  iam_instance_profile   = aws_iam_instance_profile.frontend_profile.name

  tags = { Name = "tier1-frontend" }
}

#B instance streaming
resource "aws_instance" "streaming" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.streaming_sg.id]
  key_name               = "streaming-key"

  tags = { Name = "tier2-streaming" }
}

#C intance database
resource "aws_instance" "database" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.database_sg.id]
  key_name               = "streaming-key"

  tags = { Name = "tier3-database" }
}

#D creation des instances load balancer
#creation du load balancer
resource "aws_lb" "main" {
  name               = "streaming-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.alb1.id, aws_subnet.alb2.id]

  tags = { Name = "streaming-lab-alb" }
}

resource "aws_lb_target_group" "frontend" {
  name     = "frontend-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "streaming-lab-frontend-tg" }
}


resource "aws_lb_target_group_attachment" "frontend" {
  target_group_arn = aws_lb_target_group.frontend.arn
  target_id        = aws_instance.frontend.id
  port             = 80
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

#creation d'un parametre ssm pour; d'un iam-role et d'une policy lié a cet iam

#creation du secret le parametre ssm

resource "aws_ssm_parameter" "database_password" {
  name  = "/streaming-app/db-password"
  type  = "SecureString"
  value = "Monpassword2026db_secret"

  tags = { Name = "mot_de_passe_base_de_donnees" }
}

#creation d'un role iam
resource "aws_iam_role" "frontend_role" {
  name = "frontend-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = { Name = "role pour le service frontend" }
}

# creation d'une policy attache a notre role frontend_role qui ne poura que faire une action lire le mot-de-passe de tier3

resource "aws_iam_role_policy" "read_secret_only" {
  name = "read-db-secret-only"
  role = aws_iam_role.frontend_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action   = "ssm:GetParameter"
      Effect   = "Allow"
      Resource = aws_ssm_parameter.database_password.arn
    }]
  })
}

#creation d'une instance profile qui va faire la liason entre mon instance frontend et le role iam_frontend

resource "aws_iam_instance_profile" "frontend_profile" {
  name = "frontend-profile"
  role = aws_iam_role.frontend_role.name

}

