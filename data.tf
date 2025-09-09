data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "bedrock_shipping_agent" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-instant-v1"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [
      module.lambda_shipping.lambda_function_arn
    ]
  }
}

data "aws_iam_policy_document" "bedrock_orchestrator_agent" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:GetInferenceProfile",
      "bedrock:GetFoundationModel"
    ]
    resources = [
      "arn:aws:bedrock:${data.aws_region.current.region}:*:inference-profile/us.amazon.nova-pro-v1:0",
      "arn:aws:bedrock:*::foundation-model/amazon.nova-pro-v1:0",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "bedrock:GetAgentAlias",
      "bedrock:InvokeAgent"
    ]
    resources = [
      aws_bedrockagent_agent.shipping.agent_arn,
      aws_bedrockagent_agent.order_taker.agent_arn,
      aws_bedrockagent_agent_alias.shipping.agent_alias_arn,
      aws_bedrockagent_agent_alias.order_taker.agent_alias_arn,
    ]
  }
}

data "aws_iam_policy_document" "bedrock_order_taker_agent" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream"
    ]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-instant-v1"
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction"
    ]
    resources = [
      module.lambda_order_taker.lambda_function_arn
    ]
  }
}

data "aws_iam_policy_document" "lambda_websocket_default" {
  version = "2012-10-17"
  statement {
    effect = "Allow"
    actions = [
      "execute-api:ManageConnections"
    ]
    resources = [
      format("%s/*", module.apigw_websocket.stage_execution_arn)
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "bedrock:InvokeAgent"
    ]
    resources = [
      aws_bedrockagent_agent.orchestrator.agent_arn,
      aws_bedrockagent_agent_alias.orchestrator.agent_alias_arn,
    ]
  }
}
