
# what I have build

three node cluster (one control plane and two worker nodes)

# Basic terraform setup

0. have an account ready to be used and set it up using the aws cli
1. create main.tf
2. setup provider x terraform init
3. start creating the resources
4. make sure to have the AWS CLI setup

## Step 1 create the VPC

```terraform
resource "aws_vpc" "kubeadm_vpc" {

  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = {
    
    Name = "kubeadm_test"
  }

}
```

## Step 2 create a public subnet

```terraform
resource "aws_subnet" "kubeadm_public_subnet" {

  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "kubeadm public subnet"
  }

}
```

for this to work as intended we need to create an internet gateway
and update the vpc route table to point web traffic to the subnet

## step 3 create an internet gateway and attach it to the VPC

```terraform
resource "aws_internet_gateway" "kubeadm_igw" {
  vpc_id = aws_vpc.kubeadm_vpc.id

  tags = {
    Name = "Kubeadm Internet GW"
  }

}
```

## step 4 create a route table (0.0.0.0/0 to -> IGW) and attach it to the subnet

```terraform
resource "aws_route_table" "kubeadm_main_routetable" {
  vpc_id = aws_vpc.kubeadm_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.kubeadm_igw.id
  }

  tags = {
    Name = "kubeadm IGW route table"
  }

}

resource "aws_route_table_association" "kubeadm_route_association" {
  subnet_id = aws_subnet.kubeadm_public_subnet.id
  route_table_id = aws_route_table.kubeadm_main_routetable.id
}
```

## step5b create the security groups for http(s) and ssh

```terraform
resource "aws_security_group" "allow_inbound_ssh" {
  name = "general-allow-ssh"
  tags = {
    Name = "Allow SSH"
  }

  ingress {

    description = "Allow SSH"
    protocol = "tcp"

    from_port = 22
    to_port = 22
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "allow_http" {
  name = "general-allow-http"
  tags = {
    Name = "Allow http(s)"
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


```



## Step 6 create three nodes inside the subnet and attach the security group to them

[docs](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
2Gb or RAM x 2 CPUs for the control plane node

t2 medium

first create a key-pair

1. add the following provider

```terraform
tls = {
  source = "hashicorp/tls"
  version = "4.0.4"
}
```

2. create a private key

```terraform
resource "tls_private_key" "private_key" {

  algorithm = "RSA"
  rsa_bits  = 4096
  provisioner "local-exec" { # Create a "pubkey.pem" to your computer!!
    command = "echo '${self.public_key_pem}' > ./pubkey.pem"
  }
}
```

3. Create a key pair and output the private key locally

```terraform
resource "aws_key_pair" "kubeadm_key_pair" {
  key_name = "kubeadm"
  public_key = tls_private_key.private_key.public_key_openssh

  provisioner "local-exec" { # Create a "myKey.pem" to your computer!!
    command = "echo '${tls_private_key.private_key.private_key_pem}' > ./myKey.pem"
  }
}
```

### step 7: create the control plane node

```terraform
resource "aws_instance" "kubeadm_control_plane" {
  ami = "ami-053b0d53c279acc90"
  instance_type = "t2.medium"
  key_name = aws_key_pair.kubeadm_key_pair.key_name
  associate_public_ip_address = true
  security_groups = [
    aws_security_group.allow_inbound_ssh.name,
    aws_security_group.flannel_sg.name,
    aws_security_group.allow_http.name,
    aws_security_group.kubeadm_security_group_control_plane.name
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 14
  }

  tags = {
    Name = "Kubeadm Master"
    Role = "Control plane node"
  }
}
```

### step 8: create the worker nodes

```terraform
resource "aws_instance" "kubeadm_worker_nodes" {
  count = 2
  ami = "ami-053b0d53c279acc90"
  instance_type = "t2.micro"
  key_name = aws_key_pair.kubeadm_key_pair.key_name
  associate_public_ip_address = true
  security_groups = [
    aws_security_group.allow_inbound_ssh.name,
    aws_security_group.flannel_sg.name,
    aws_security_group.allow_http.name,
    aws_security_group.worker_node_sg.name
  ]
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  tags = {
    Name = "Kubeadm Worker ${count.index}"
    Role = "Worker node"
  }

}

```

### step 9: create the ansible hosts

go to the blog post and install the plugin

```bash
ansible-galaxy collection install cloud.terraform
```

```terraform
resource "ansible_host" "kubadm_host" {
  depends_on = [
    aws_instance.kubeadm_control_plane
  ]
  name = "control_plane"
  groups = ["master"]
  variables = {
    ansible_user = "root"
    ansible_host = aws_instance.kubeadm_control_plane.public_ip
    ansible_ssh_private_key_file = "./myKey.pem"
    node_hostname = "master"
  }
}

resource "ansible_host" "worker_nodes" {
  depends_on = [
    aws_instance.kubeadm_worker_nodes
  ]
  count = 2
  name = "worker-${count.index}"
  groups = ["workers"]
  variables = {
    node_hostname = "worker-${count.index}"
    ansible_user = "root"
    ansible_host = aws_instance.kubeadm_worker_nodes[count.index].public_ip
    ansible_ssh_private_key_file = "./myKey.pem"
  }
}
```



### step 11: run the playbook

```bash
chmod 600 myKey.pem
ansible-playbook -i inventory.yml playbook.yml
```

### step 12: cat the kubeconfig

### step 13: verify that everything works

```bash
kubectl get nodes
kubectl create -f deploy.yaml
```

### do a bit of refactoring with outputs and variables

### end the video
