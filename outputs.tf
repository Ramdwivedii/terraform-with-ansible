output "control_plane_ip" {
  value = aws_instance.kubeadm_control_plane.public_ip
}

output "worker_nodes_ip" {
  value = join("", aws_instance.kubeadm_worker_nodes[*].public_ip)
}

