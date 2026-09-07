provider "aws" { region = "eu-west-3" }

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = { Name = "streaming_lab_vpc" }

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
