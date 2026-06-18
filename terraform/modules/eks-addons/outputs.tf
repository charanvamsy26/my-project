output "aws_load_balancer_controller_installed" {
  description = "Whether the AWS Load Balancer Controller Helm release was created."
  value       = var.enable_aws_load_balancer_controller
}

output "aws_load_balancer_controller_release_name" {
  description = "Helm release name of the AWS Load Balancer Controller (empty if disabled)."
  value       = try(helm_release.aws_load_balancer_controller[0].name, "")
}

output "metrics_server_installed" {
  description = "Whether metrics-server was installed."
  value       = var.enable_metrics_server
}

output "metrics_server_release_name" {
  description = "Helm release name of metrics-server (empty if disabled)."
  value       = try(helm_release.metrics_server[0].name, "")
}
