terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.4.0"
    }
    tls = {
      source = "hashicorp/tls"
      version = "4.0.4"
    }
    ansible = {
      source = "ansible/ansible"
      version = "1.1.0"
    }

  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_vpc" "my_vpc" {

  cidr_block = var.vpc_cidr_block
  enable_dns_hostnames = true

  tags = {

    Name = "my_vpc"
    "kubernetes.io/cluster/kubernetes" = "owned"
  }
  
}

resource "aws_subnet" "my_subnet" {

  vpc_id = aws_vpc.my_vpc.id
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = { 
    Name = "tf_public_subnet"
  }
  
}

resource "aws_internet_gateway" "sub_igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = { 
    Name = "tf Internet GW"
  }

}

resource "aws_route_table" "sub_routetable" {
  vpc_id = aws_vpc.my_vpc.id

  route { 
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sub_igw.id
  }

  tags = {
    Name = "tf IGW route table"
  }

}

resource "aws_route_table_association" "route_association" {
  subnet_id = aws_subnet.my_subnet.id
  route_table_id = aws_route_table.sub_routetable.id
}

resource "aws_security_group" "sg_flannel" {
  name = "flannel-overlay-backend"
  tags = {
    Name = "Flannel Overlay backend"
  }

  ingress {
    description = "flannel overlay backend"
    protocol = "udp"
    from_port = 8285
    to_port = 8285
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    description = "flannel vxlan backend"
    protocol = "udp"
    from_port = 8472
    to_port =  8472
    cidr_blocks = ["0.0.0.0/0"]
  }
  
}

resource "aws_security_group" "sg_common" {
  name = "common-ports"
  tags = { 
    Name = "common ports"
  }
  
  ingress {
    description = "Allow SSH"
    protocol = "tcp"
    from_port = 22
    to_port = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTP"
    protocol = "tcp"
    from_port = 80
    to_port = 80 
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow HTTPS"
    protocol = "tcp"
    from_port = 443
    to_port = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }


}
resource "aws_security_group" "sg_control_plane" {
  name = "kubeadm-control-plane security group"
  ingress {
    description = "API Server"
    protocol = "tcp"
    from_port = 6443
    to_port = 6443
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kubelet API"
    protocol = "tcp"
    from_port = 2379
    to_port = 2380
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "etcd server client API"
    protocol = "tcp"
    from_port = 10250
    to_port = 10250
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kube Scheduler"
    protocol = "tcp"
    from_port = 10259
    to_port = 10259
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kube Contoller Manager"
    protocol = "tcp"
    from_port = 10257
    to_port = 10257
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { 
    Name = "Control Plane SG"
  }
}


resource "aws_security_group" "sg_worker_nodes" {
  name = "kubeadm-worker-node security group"

  ingress {
    description = "kubelet API"
    protocol = "tcp"
    from_port = 10250
    to_port = 10250
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "NodePort services"
    protocol = "tcp"
    from_port = 30000
    to_port = 32767
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { 
    Name = "Worker Nodes SG"
  }
  
}

resource "tls_private_key" "kubadm_private_key" {
  
  algorithm = "RSA"
  rsa_bits  = 4096

  provisioner "local-exec" { # Create a "pubkey.pem" to your computer!!
    command = "echo '${self.public_key_pem}' > ./pubkey.pem"
  }
}

resource "aws_key_pair" "kubeadm_key_pair" {
  key_name = var.keypair_name
  public_key = tls_private_key.kubadm_private_key.public_key_openssh

  provisioner "local-exec" { 
    command = "echo '${tls_private_key.kubadm_private_key.private_key_pem}' > ./private-key.pem"
  }
  
}

resource "aws_instance" "kubeadm_control_plane" {
  ami = var.ubuntu_ami
  instance_type = "t2.medium"
  key_name = aws_key_pair.kubeadm_key_pair.key_name
  associate_public_ip_address = true
  security_groups = [
    aws_security_group.sg_common.name,
    aws_security_group.sg_flannel.name,
    aws_security_group.sg_control_plane.name,
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 14
  }

  tags = {
    Name = "Kubeadm Master"
    Role = "Control plane node"
  }

  provisioner "local-exec" {
    command = "echo 'master ${self.public_ip}' >> ./files/hosts"
  }

}

resource "aws_instance" "kubeadm_worker_nodes" {
  count = var.worker_nodes_count
  ami = var.ubuntu_ami
  instance_type = "t2.micro"
  key_name = aws_key_pair.kubeadm_key_pair.key_name
  associate_public_ip_address = true
  security_groups = [
    aws_security_group.sg_flannel.name,
    aws_security_group.sg_common.name,
    aws_security_group.sg_worker_nodes.name,
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  tags = {
    Name = "Kubeadm Worker ${count.index}"
    Role = "Worker node"
  }

  provisioner "local-exec" {
    command = "echo 'worker-${count.index} ${self.public_ip}' >> ./files/hosts"
  }
  
}

resource "ansible_host" "kubadm_control_plane_host" {
  depends_on = [
    aws_instance.kubeadm_control_plane
  ]
  name = "control_plane"
  groups = ["master"]
  variables = {
    ansible_user = "ubuntu"
    ansible_host = aws_instance.kubeadm_control_plane.public_ip
    ansible_ssh_private_key_file = "./private-key.pem"
    node_hostname = "master"
  }
}

resource "ansible_host" "kubadm_worker_nodes_host" {
  depends_on = [
    aws_instance.kubeadm_worker_nodes
  ]
  count = 2
  name = "worker-${count.index}"
  groups = ["workers"]
  variables = {
    node_hostname = "worker-${count.index}"
    ansible_user = "ubuntu"
    ansible_host = aws_instance.kubeadm_worker_nodes[count.index].public_ip
    ansible_ssh_private_key_file = "./private-key.pem"
  }
}
