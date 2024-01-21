# Terraform 설정 및 AWS 프로바이더 정의
provider "aws" {
  region = "ap-northeast-2"
}

# VPC 생성
resource "aws_vpc" "eks_work_vpc" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "eks-work-VPC"
  }
}

# Elastic IP 생성
resource "aws_eip" "elastic_ip_address" {
  domain = "vpc"
}

# NAT 게이트웨이 생성
resource "aws_nat_gateway" "bastion_nat_gateway" {
  allocation_id = aws_eip.elastic_ip_address.id
  subnet_id     = aws_subnet.bastion_sn1.id

  tags = {
    Name = "eks-work-BastionNatGateway"
  }
}

# Worker 노드용 보안 그룹 생성
resource "aws_security_group" "worker_node_sg" {
  name        = "eks-work-WorkerNodeSG"
  description = "Security Group for EKS Worker Nodes"
  vpc_id      = aws_vpc.eks_work_vpc.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion_host_sg.id]
  }

  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion_host_sg.id]
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion_host_sg.id]
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    security_groups = [aws_security_group.bastion_host_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-work-WorkerNodeSG"
  }
}

# 서브넷 생성 (WorkerSubnet1)
resource "aws_subnet" "worker_subnet1" {
  availability_zone = "ap-northeast-2a"
  cidr_block        = "192.168.11.0/24"
  vpc_id            = aws_vpc.eks_work_vpc.id
  map_public_ip_on_launch = false

  tags = {
    Name = "eks-work-WorkerSubnet1"
  }
}

# 서브넷 생성 (WorkerSubnet2)
resource "aws_subnet" "worker_subnet2" {
  availability_zone = "ap-northeast-2c"
  cidr_block        = "192.168.12.0/24"
  vpc_id            = aws_vpc.eks_work_vpc.id
  map_public_ip_on_launch = false

  tags = {
    Name = "eks-work-WorkerSubnet2"
  }
}

# Internet Gateway 생성
resource "aws_internet_gateway" "internet_gateway" {
  vpc_id = aws_vpc.eks_work_vpc.id
}

# 클러스터 라우팅테이블
resource "aws_route_table" "cluster_route_table" {
  vpc_id = aws_vpc.eks_work_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }
  tags = {
    Name = "eks-work-ClusterRouteTable"
  }
}


resource "aws_route_table_association" "cluster_sn1_rta" {
  subnet_id      = aws_subnet.worker_subnet1.id
  route_table_id = aws_route_table.cluster_route_table.id
}

resource "aws_route_table_association" "cluster_sn2_rta" {
  subnet_id      = aws_subnet.worker_subnet2.id
  route_table_id = aws_route_table.cluster_route_table.id
}

# 배스천 호스트 IAM 역할 및 정책, 인스턴스 프로필 생성
resource "aws_iam_role" "bastion_role" {
  name = "eks-work-BastionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# 배스천 IAM 정책
resource "aws_iam_role_policy_attachment" "bastion_eks_cni_policy" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "bastion_eks_worker_node_policy" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "bastion_ec2_container_registry_read_only" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_eks_cluster_policy" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cluster_eks_service_policy" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}


resource "aws_iam_instance_profile" "eks_node_instance_profile" {
  name = "eks-work-EksNodeInstanceProfile"
  role = aws_iam_role.bastion_role.name
}


# EKS 클러스터 생성
resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks-work-Cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids         = [aws_subnet.worker_subnet1.id, aws_subnet.worker_subnet2.id]
    security_group_ids = [aws_security_group.worker_node_sg.id]
    endpoint_public_access = false
    endpoint_private_access = true
  }

  version = "1.28"
}

# EKS 노드 그룹 생성
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-work-NodeGroup"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.worker_subnet1.id, aws_subnet.worker_subnet2.id]

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  remote_access {
    ec2_ssh_key               = "elb-public"
    source_security_group_ids = [aws_security_group.worker_node_sg.id]
  }
}

# EKS 노드 그룹을 위한 IAM 역할 생성
resource "aws_iam_role" "eks_node_role" {
  name = "eks-work-NodeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    "Name" = "eks-work-NodeRole"
  }
}

# EKS 노드 역할에 필요한 관리형 정책 첨부
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_worker_ec2_container_registry_read_only" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "eks_worker_eks_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_worker_route53_full_access" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

resource "aws_iam_role_policy_attachment" "eks_worker_eks_Node_cluster_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_worker_eks_Node_service_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}


# EKS 클러스터를 위한 IAM 역할 생성
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-work-ClusterRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "eks.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    "Name" = "eks-work-ClusterRole"
  }
}

# EKS 클러스터 역할에 필요한 관리형 정책 첨부
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_service_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSServicePolicy"
}

# 배스천 호스트용 서브넷 생성
resource "aws_subnet" "bastion_sn1" {
  vpc_id            = aws_vpc.eks_work_vpc.id
  cidr_block        = "192.168.0.0/24"
  availability_zone = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name = "eks-work-BastionSN1"
  }
}

# 배스천 호스트용 보안 그룹 생성
resource "aws_security_group" "bastion_host_sg" {
  name        = "eks-work-BastionSG"
  description = "Security Group for Bastion Host"
  vpc_id      = aws_vpc.eks_work_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"  # -1은 모든 프로토콜을 나타냅니다.
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-work-BastionSG"
  }
}

# 배스천 호스트용 라우팅 테이블 생성
resource "aws_route_table" "bastion_rt" {
  vpc_id = aws_vpc.eks_work_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "eks-work-BastionRT"
  }
}

# 배스천 서브넷과 라우팅 테이블 연결
resource "aws_route_table_association" "bastion_sn1_rta" {
  subnet_id      = aws_subnet.bastion_sn1.id
  route_table_id = aws_route_table.bastion_rt.id
}

# 배스천 호스트 EC2 인스턴스 생성
resource "aws_instance" "bastion_host" {
  ami                         = "ami-04ab8d3a67dfe6398"
  instance_type               = "t2.micro"
  key_name                    = "elb-public"
  subnet_id                   = aws_subnet.bastion_sn1.id
  vpc_security_group_ids      = [aws_security_group.bastion_host_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.eks_node_instance_profile.name
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    yum -y install wget
    sudo -u ec2-user mkdir -p ~/.kube
    wget -O /home/ec2-user/kubectl https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl
    chmod +x /home/ec2-user/kubectl
    mkdir -p /home/ec2-user/.kube
    mv /home/ec2-user/kubectl /usr/bin/kubectl
    aws eks update-kubeconfig --region ap-northeast-2 --name eks-work-Cluster
    chown -R ec2-user:ec2-user /home/ec2-user/
  EOF

  tags = {
    Name = "eks-work-BastionHost"
  }

  depends_on = [
    aws_eks_cluster.eks_cluster
  ]
}