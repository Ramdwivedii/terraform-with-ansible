variable "vpc_cidr_block" {
  type = string
  description = "vpc default cidr block"
  default = "10.0.0.0/16"
}

variable "ubuntu_ami" {
  type = string
  description = "the AMI ID of our linux instance"
  default = "ami-053b0d53c279acc90"
}

variable "worker_nodes_count" {
  type = number
  description = "the total number of worker nodes"
  default = 2
}

variable "keypair_name" {
  type = string
  description = "the name of our keypair"
  default = "kubeadm_demo"
}
