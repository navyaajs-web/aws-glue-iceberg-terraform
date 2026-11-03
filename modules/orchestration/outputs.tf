output "state_machine_arn" {
  description = "ARN of the Step Functions state machine."
  value       = aws_sfn_state_machine.this.arn
}

output "state_machine_name" {
  description = "Name of the Step Functions state machine."
  value       = aws_sfn_state_machine.this.name
}

output "alerts_topic_arn" {
  description = "ARN of the SNS topic that receives failure alerts."
  value       = aws_sns_topic.alerts.arn
}

output "role_arn" {
  description = "ARN of the state machine execution role."
  value       = aws_iam_role.state_machine.arn
}

output "definition_json" {
  description = "Rendered Amazon States Language definition (useful for review and tests)."
  value       = jsonencode(local.definition)
}
