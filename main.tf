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

# 1. Sous-réseau public
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags                    = { Name = "streaming_public_subnet" }
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

# 4. Association du sous-réseau à la table de routage
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
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
    description     = "ingestion des flux video depuis le serveur de streaming tier2 uniquement"
    from_port       = 1935
    to_port         = 1935
    protocol        = "tcp"
    security_groups = [aws_security_group.streaming_sg.id]
  }

  ingress {
    description = "SSH access from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["212.222.174.113/32"]
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
    description = "SSH access from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["212.222.174.113/32"]
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
    description = "SSH access from admin IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["212.222.174.113/32"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "streaming-lab-database" }
}

#creation des instance pour les 3 tiers

#A instance frontend
resource "aws_instance" "frontend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.frontend_sg.id]
  key_name               = "streaming-key"
  iam_instance_profile	 = aws_iam_instance_profile.frontend_profile.name

  tags = { Name = "tier1-frontend" }
}

#B instance streaming
resource "aws_instance" "streaming" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.streaming_sg.id]
  key_name               = "streaming-key"

  tags = { Name = "tier2-streaming" }
}

#C intance database
resource "aws_instance" "database" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.database_sg.id]
  key_name               = "streaming-key"

  tags = { Name = "tier3-database" }
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
    Action    = "ssm:GetParameter"
    Effect    = "Allow"
    Resource = aws_ssm_parameter.database_password.arn
    }]
  })
}

#creation d'une instance profile qui va faire la liason entre mon instance frontend et le role iam_frontend

resource "aws_iam_instance_profile" "frontend_profile" {
  name = "frontend-profile"
  role = aws_iam_role.frontend_role.name

}

