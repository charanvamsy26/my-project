###############################################################################
# Karpenter prerequisites (AWS-side)
#
# Karpenter has two halves:
#   1. The CONTROLLER (Helm) — its IRSA role is created in the iam-irsa layer
#      using the policy template shipped there; it consumes the queue ARN and
#      node role ARN exported by THIS module.
#   2. The data-plane plumbing below: a node IAM role/instance profile for the
#      EC2 instances Karpenter launches, and an SQS queue fed by EventBridge so
#      Karpenter can gracefully drain spot interruptions / instance state changes.
#
# Karpenter-launched nodes reuse the same node IAM role as the managed node group.
###############################################################################

locals {
  karpenter_enabled = var.enable_karpenter_prerequisites
}

# Instance profile wrapping the shared node role, discoverable by Karpenter via
# the EC2NodeClass `role` reference.
resource "aws_iam_instance_profile" "karpenter_node" {
  count = local.karpenter_enabled ? 1 : 0
  name  = "${var.cluster_name}-karpenter-node"
  role  = aws_iam_role.node.name
  tags  = var.tags
}

###############################################################################
# Interruption handling — SQS queue + EventBridge rules
###############################################################################

resource "aws_sqs_queue" "karpenter" {
  count                     = local.karpenter_enabled ? 1 : 0
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300 # interruption signals are short-lived
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

data "aws_iam_policy_document" "karpenter_queue" {
  count = local.karpenter_enabled ? 1 : 0

  statement {
    sid       = "AllowEventBridgeToSendMessages"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter[0].arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  count     = local.karpenter_enabled ? 1 : 0
  queue_url = aws_sqs_queue.karpenter[0].url
  policy    = data.aws_iam_policy_document.karpenter_queue[0].json
}

# Each EventBridge rule forwards a class of EC2 lifecycle event to the queue so
# Karpenter can react (cordon/drain) before the instance disappears.
locals {
  karpenter_events = local.karpenter_enabled ? {
    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }
    instance_state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }
  } : {}
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.karpenter_events

  name = "${var.cluster_name}-karpenter-${each.key}"
  event_pattern = jsonencode({
    source      = each.value.source
    detail-type = each.value.detail_type
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = local.karpenter_events

  rule      = aws_cloudwatch_event_rule.karpenter[each.key].name
  target_id = "karpenter-queue"
  arn       = aws_sqs_queue.karpenter[0].arn
}
