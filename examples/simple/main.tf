###########################
# Supporting resources
###########################
# This needs Python on the container... RIP

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 3.3.1"

  function_name = "hello-world-lambda"
  description   = "Hello-World lambda function"

  handler = "index.lambda_handler"
  runtime = "python3.8"

  publish = true

  create_package = true

  source_path = "../test_infrastructure/src_lambda"

  allowed_triggers = {
    AllowExecutionFromAPIGateway = {
      service = "apigateway"
      arn     = module.api_gateway.rest_api_execution_arn
    }
  }
}

module "api_gateway" {
  source = "../..//."

  api_gateway = {
    name          = "api-gateway"
    custom_domain = "api-gateway-v1.test.cloud.mdlz.com"
  }

  api_gateway_stages = [
    {
      stage_name        = "main"
      stage_description = "The stage defined for main, tied to the default deployment."
    }
  ]
  api_gateway_methods = [
    {
      resource_path = "myPath"
      api_method = {
        authorization = "NONE"
        integration = {
          uri = module.lambda_function.lambda_function_invoke_arn
        }
        http_method = "GET"
      }
    },
    {
      resource_path = "myPath"
      api_method = {
        authorization = "NONE"
        integration = {
          uri = module.lambda_function.lambda_function_invoke_arn
        }
        http_method = "POST"
      }
    }
  ]
}
