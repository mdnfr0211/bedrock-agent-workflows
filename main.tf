# Shipment Agent

resource "aws_bedrockagent_agent" "shipping" {
  agent_collaboration         = "DISABLED"
  agent_name                  = "ShippingAgent"
  agent_resource_role_arn     = module.bedrock_shipping_agent_role.arn
  foundation_model            = "anthropic.claude-instant-v1"
  idle_session_ttl_in_seconds = 600
  instruction                 = "Your only job is to dispatch an order and provide a tracking number for a given order_id using your tool. Only perform this action when explicitly instructed. Do not create orders, check inventory, or process payments."
  prepare_agent               = true
}

resource "aws_bedrockagent_agent_action_group" "shipping" {
  action_group_name          = "shipping"
  agent_id                   = aws_bedrockagent_agent.shipping.agent_id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true
  action_group_executor {
    lambda = module.lambda_shipping.lambda_function_arn
  }
  function_schema {
    member_functions {
      functions {
        name = "dispatch-shipment"
        parameters {
          map_block_key = "order_id"
          type          = "string"
          description   = "Order ID"
          required      = true
        }
      }
    }
  }
}

resource "aws_bedrockagent_agent_alias" "shipping" {
  agent_alias_name = "v1"
  agent_id         = aws_bedrockagent_agent.shipping.agent_id
}

resource "aws_bedrockagent_agent_collaborator" "shipping" {
  agent_id                   = aws_bedrockagent_agent.orchestrator.agent_id
  collaboration_instruction  = "Dispatches a paid order using an order_id and provides a tracking number. Use this as the final step after payment is confirmed.\n"
  collaborator_name          = "ShippingAgent"
  prepare_agent              = true
  relay_conversation_history = "DISABLED"
  agent_descriptor {
    alias_arn = aws_bedrockagent_agent_alias.shipping.agent_alias_arn
  }
}

module "bedrock_shipping_agent_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "shipping-agent-role"

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
      ]
      effect = "Allow",
      principals = [{
        type = "Service"
        identifiers = [
          "bedrock.amazonaws.com",
        ]
      }]
    }
  }

  policies = {
    custom = module.bedrock_shipping_agent_policy.arn
  }
}

module "bedrock_shipping_agent_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 6.0"

  name = "shipping-agent-policy"
  path = "/"

  policy = data.aws_iam_policy_document.bedrock_shipping_agent.json
}

module "lambda_shipping" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "dispatchShipment"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/dispatchShipment.zip"

  memory_size = 512
  timeout     = 60

  create_current_version_allowed_triggers   = false
  create_unqualified_alias_allowed_triggers = true

  allowed_triggers = {
    bedrock = {
      principal  = "bedrock.amazonaws.com"
      source_arn = aws_bedrockagent_agent.shipping.agent_arn
    }
  }

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    ddb = {
      actions = [
        "dynamodb:UpdateItem",
      ]
      resources = [
        module.ddb_order.dynamodb_table_arn
      ]
    }
  }

  environment_variables = {
    OrderTable = module.ddb_order.dynamodb_table_id
  }
}

# Supervisor Agent

resource "aws_bedrockagent_agent" "orchestrator" {
  agent_collaboration         = "SUPERVISOR"
  agent_name                  = "EcommerceOrchestrator"
  agent_resource_role_arn     = module.bedrock_orchestrator_agent_role.arn
  foundation_model            = "arn:aws:bedrock:us-east-1:${data.aws_caller_identity.current.id}:inference-profile/us.amazon.nova-pro-v1:0"
  idle_session_ttl_in_seconds = 600
  instruction                 = "You are a strict, procedural e-commerce orchestrator. You MUST follow the operational sequence exactly as defined. \n\n1. **Order Initiation**: When a user wants to order a product, your first action is to invoke the **OrderTakerAgent**, passing it the product_id, quantity. This agent handles both inventory checking and order creation. If it reports an out-of-stock error, stop the process and inform the user. Once the order_id generated, Generate the Payment Link and Return to the User \n\n2.  **Shipping**: When you receive an ACTION_PROMPT about a successful payment, find the `order_id` in the `$prompt_session_attributes$`. You MUST immediately invoke the **ShippingAgent**, passing this `order_id` to it.\n\n3.  **Final Confirmation**: After the ShippingAgent returns a tracking number, provide the final confirmation and the tracking number to the user.\n"
  prepare_agent               = true
}

resource "aws_bedrockagent_agent_alias" "orchestrator" {
  agent_alias_name = "v1"
  agent_id         = aws_bedrockagent_agent.orchestrator.agent_id
}

module "bedrock_orchestrator_agent_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "orchestrator-agent-role"

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
      ]
      principals = [{
        type = "Service"
        identifiers = [
          "bedrock.amazonaws.com",
        ]
      }]
    }
  }

  policies = {
    custom = module.bedrock_orchestrator_agent_policy.arn
  }
}

module "bedrock_orchestrator_agent_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 6.0"

  name = "orchestrator-agent-policy"
  path = "/"

  policy = data.aws_iam_policy_document.bedrock_orchestrator_agent.json
}

# Order Taker Agent

resource "aws_bedrockagent_agent" "order_taker" {
  agent_collaboration         = "DISABLED"
  agent_name                  = "OrderTakerAgent"
  agent_resource_role_arn     = module.bedrock_order_taker_agent_role.arn
  foundation_model            = "anthropic.claude-instant-v1"
  idle_session_ttl_in_seconds = 600
  instruction                 = "You are responsible for the initial phase of order processing. Your tool performs two functions: it first checks inventory for a given product_id and quantity, and if successful, it creates an order record. Your job is to take the product_id and quantity from the user's request, invoke your tool, and report the outcome. If successful, you must return the new order_id and payment url. If the inventory check fails, you must report the out of stock reason clearly."
  prepare_agent               = true
}

resource "aws_bedrockagent_agent_action_group" "order_taker" {
  action_group_name          = "OrderTakerAgent"
  agent_id                   = aws_bedrockagent_agent.order_taker.agent_id
  agent_version              = "DRAFT"
  skip_resource_in_use_check = true
  action_group_executor {
    lambda = module.lambda_order_taker.lambda_function_arn
  }
  function_schema {
    member_functions {
      functions {
        name = "create-order"
        parameters {
          map_block_key = "quantity"
          type          = "integer"
          description   = "Number of Items to be Ordered"
          required      = true
        }
        parameters {
          map_block_key = "product_id"
          type          = "string"
          description   = "Product ID to Order"
          required      = true
        }
      }
    }
  }
}

resource "aws_bedrockagent_agent_alias" "order_taker" {
  agent_alias_name = "v1"
  agent_id         = aws_bedrockagent_agent.order_taker.agent_id
}

resource "aws_bedrockagent_agent_collaborator" "order_taker" {
  agent_id                   = aws_bedrockagent_agent.orchestrator.agent_id
  collaboration_instruction  = "When a user places an order, use the product ID, and quantity. Use your tool to create an order and return the order_id"
  collaborator_name          = "OrderTakerAgent"
  prepare_agent              = true
  region                     = "us-east-1"
  relay_conversation_history = "DISABLED"
  agent_descriptor {
    alias_arn = aws_bedrockagent_agent_alias.order_taker.agent_alias_arn
  }
}

module "bedrock_order_taker_agent_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "order-taker-agent-role"

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
      ]
      principals = [{
        type = "Service"
        identifiers = [
          "bedrock.amazonaws.com",
        ]
      }]
    }
  }

  policies = {
    custom = module.bedrock_order_taker_agent_policy.arn
  }
}

module "bedrock_order_taker_agent_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 6.0"

  name = "order-taker-agent-policy"
  path = "/"

  policy = data.aws_iam_policy_document.bedrock_order_taker_agent.json
}

module "lambda_order_taker" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "createOrder"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/createOrder.zip"

  memory_size = 512
  timeout     = 60

  create_current_version_allowed_triggers   = false
  create_unqualified_alias_allowed_triggers = true

  allowed_triggers = {
    bedrock = {
      principal  = "bedrock.amazonaws.com"
      source_arn = aws_bedrockagent_agent.order_taker.agent_arn
    }
  }

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    ddb = {
      actions = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
      ]
      resources = [
        module.ddb_order.dynamodb_table_arn,
        module.ddb_products.dynamodb_table_arn,
      ]
    }
  }
  environment_variables = {
    OrderTable        = module.ddb_order.dynamodb_table_id
    ProductTable      = module.ddb_products.dynamodb_table_id
    PaymentGatewayURL = module.apigw_payment.stage_invoke_url
  }
}

module "ddb_order" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 5.0"

  name     = "MultiAgentOrders"
  hash_key = "order_id"

  attributes = [
    {
      name = "order_id"
      type = "S"
    }
  ]
}

module "ddb_products" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 5.0"

  name     = "Products"
  hash_key = "product_id"

  attributes = [
    {
      name = "product_id"
      type = "S"
    }
  ]
}

# Payment Hook

module "eventbridge" {
  source  = "terraform-aws-modules/eventbridge/aws"
  version = "~> 4.0"

  bus_name = "payment-events"

  rules = {
    payment-status = {
      description = "Capture all order data"
      event_pattern = jsonencode({
        "source" : ["com.my-ecommerce.payment"],
        "detail-type" : ["PaymentSuccessful", "PaymentFailed"]
      })
      enabled = true
    }
  }

  targets = {
    payment-status = [
      {
        name = "lambda-payment-hook"
        arn  = module.lambda_payment_hook.lambda_function_arn
      },
    ]
  }
}

module "lambda_payment_hook" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "paymentWebhook"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/handlePaymentWebhook.zip"

  memory_size = 512
  timeout     = 60

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    ddb = {
      actions = [
        "dynamodb:DeleteItem",
        "dynamodb:GetItem",
        "dynamodb:Query",
        "dynamodb:UpdateItem",
      ]
      resources = [
        module.ddb_order.dynamodb_table_arn,
        module.ddb_websocket_connection.dynamodb_table_arn,
        "${module.ddb_websocket_connection.dynamodb_table_arn}/*"
      ]
    }
    bedrock = {
      actions = [
        "bedrock:InvokeAgent",
      ]
      resources = [
        aws_bedrockagent_agent.orchestrator.agent_arn,
        aws_bedrockagent_agent_alias.orchestrator.agent_alias_arn,
      ]
    }
    apigw = {
      actions = [
        "execute-api:ManageConnections"
      ]
      resources = [
        format("%s/*", module.apigw_websocket.stage_execution_arn)
      ]
    }
  }
  environment_variables = {
    OrderTable         = module.ddb_order.dynamodb_table_id
    WebSocketTable     = module.ddb_websocket_connection.dynamodb_table_id
    AgentID            = aws_bedrockagent_agent.orchestrator.agent_id
    AgentAliasID       = aws_bedrockagent_agent_alias.orchestrator.agent_alias_id
    ApiGatewayEndpoint = "" #https://<apigw-id>.execute-api.<region>.amazonaws.com/<stage>
  }
}

resource "aws_lambda_permission" "allow_eventbridge" {
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_payment_hook.lambda_function_name
  principal     = "events.amazonaws.com"
  source_arn    = module.eventbridge.eventbridge_rule_arns["payment-status"]
}

# Payment Gateway

module "apigw_payment" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 5.0"

  name          = "payment"
  description   = ""
  protocol_type = "HTTP"

  stage_name = "v1"

  create_domain_name    = false
  create_domain_records = false

  routes = {
    "GET /pay" = {
      integration = {
        uri                    = module.lambda_payment.lambda_function_arn
        payload_format_version = "2.0"
        timeout_milliseconds   = 30000
      }
    }
  }
}

module "lambda_payment" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "paymentPage"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/paymentPage.zip"

  memory_size = 512
  timeout     = 60

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    eventbridge = {
      actions = [
        "events:PutEvents",
      ]
      resources = [
        module.eventbridge.eventbridge_bus_arn
      ]
    }
  }
  environment_variables = {
    EvenbridgeBusName = module.eventbridge.eventbridge_bus_name
  }
}

resource "aws_lambda_permission" "allow_apigw" {
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_payment.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${module.apigw_payment.api_execution_arn}/*"
}

# WebSocket

module "apigw_websocket" {
  source  = "terraform-aws-modules/apigateway-v2/aws"
  version = "~> 5.0"

  name        = "chat"
  description = ""

  stage_name = "v1"

  create_domain_name    = false
  create_domain_records = false

  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  routes = {
    "$connect" = {
      operation_name = "connect"

      integration = {
        uri = module.lambda_websocket_connect.lambda_function_invoke_arn
      }
    },
    "$disconnect" = {
      operation_name = "disconnect"

      integration = {
        uri = module.lambda_websocket_disconnect.lambda_function_invoke_arn
      }
    },
    "$default" = {
      operation_name = "default"

      integration = {
        uri = module.lambda_websocket_default.lambda_function_invoke_arn
      }
    },
  }

  stage_default_route_settings = {
    data_trace_enabled       = false
    detailed_metrics_enabled = false
    logging_level            = "INFO"
  }
}

module "lambda_websocket_connect" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "webSocketConnect"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/webSocketConnect.zip"

  memory_size = 512
  timeout     = 60

  create_current_version_allowed_triggers   = false
  create_unqualified_alias_allowed_triggers = true

  allowed_triggers = {
    apigw = {
      service    = "apigateway"
      source_arn = "${module.apigw_websocket.api_execution_arn}/*"
    }
  }

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    ddb = {
      actions = [
        "dynamodb:PutItem",
      ]
      resources = [
        module.ddb_websocket_connection.dynamodb_table_arn
      ]
    }
  }
  environment_variables = {
    WebSocketTable = module.ddb_websocket_connection.dynamodb_table_id
  }
}

module "lambda_websocket_disconnect" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = true

  function_name = "webSocketDisconnect"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/webSocketDisconnect.zip"

  memory_size = 512
  timeout     = 60

  create_current_version_allowed_triggers   = false
  create_unqualified_alias_allowed_triggers = true

  allowed_triggers = {
    apigw = {
      service    = "apigateway"
      source_arn = "${module.apigw_websocket.api_execution_arn}/*"
    }
  }

  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
  ]

  attach_policy_statements = true
  policy_statements = {
    ddb = {
      actions = [
        "dynamodb:DeleteItem",
      ]
      resources = [
        module.ddb_websocket_connection.dynamodb_table_arn
      ]
    }
  }
  environment_variables = {
    WebSocketTable = module.ddb_websocket_connection.dynamodb_table_id
  }
}

module "lambda_websocket_default" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 8.0"

  create_package = false
  create_role    = false

  function_name = "handleChat"
  description   = ""
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"

  local_existing_package = "${path.module}/functions/handleChat.zip"

  memory_size = 512
  timeout     = 60

  create_current_version_allowed_triggers   = false
  create_unqualified_alias_allowed_triggers = true

  allowed_triggers = {
    apigw = {
      service    = "apigateway"
      source_arn = "${module.apigw_websocket.api_execution_arn}/*"
    }
  }

  lambda_role = module.lambda_websocket_default_role.arn

  environment_variables = {
    AgentID            = aws_bedrockagent_agent.orchestrator.agent_id
    AgentAliasID       = aws_bedrockagent_agent_alias.orchestrator.agent_alias_id
    ApiGatewayEndpoint = "" #https://<apigw-id>.execute-api.<region>.amazonaws.com/<stage>
  }
}

module "lambda_websocket_default_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role"
  version = "~> 6.0"

  name = "websocket-lambda-role"

  trust_policy_permissions = {
    TrustRoleAndServiceToAssume = {
      actions = [
        "sts:AssumeRole",
      ]
      principals = [{
        type = "Service"
        identifiers = [
          "lambda.amazonaws.com",
        ]
      }]
    }
  }

  policies = {
    VPCAccessExecutionRole = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
    custom                 = module.lambda_websocket_default_policy.arn
  }
}

module "lambda_websocket_default_policy" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-policy"
  version = "~> 6.0"

  name = "websocket-lambda-policy"
  path = "/"

  policy = data.aws_iam_policy_document.lambda_websocket_default.json
}

module "ddb_websocket_connection" {
  source  = "terraform-aws-modules/dynamodb-table/aws"
  version = "~> 5.0"

  name     = "WebSocketConnections"
  hash_key = "connectionId"

  attributes = [
    {
      name = "connectionId"
      type = "S"
    },
    {
      name = "sessionId"
      type = "S"
    }
  ]

  global_secondary_indexes = [
    {
      name            = "sessionId-index"
      hash_key        = "sessionId"
      projection_type = "ALL"
      write_capacity  = 1
      read_capacity   = 1
    }
  ]
}
