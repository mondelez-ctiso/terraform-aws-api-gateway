###########################
# Supporting resources
#######RIP####################

module "lambda_function" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "~> 4.0.0"

  function_name = "hello-world-lambda"
  description   = "Hello-World lambda function"
  handler       = "index.lambda_handler"
  runtime       = "python3.9"

  publish = true

  create_package = true

  source_path = "../test_infrastructure/src_lambda"

  allowed_triggers = {
    AllowExecutionFromAPIGateway = {
      service = "apigateway"
      arn     = module.api_gateway.rest_api_execution_arn
    }
  }

  layers = ["arn:aws:lambda:us-east-2:017000801446:layer:AWSLambdaPowertoolsPythonV2:46"]
}

module "api_gateway" {
  source = "../..//."

  api_gateway = {
    name                     = "simple-test-api-gateway"
    description              = "The test api-gateway"
    default_deployment_name  = "prod"
    minimum_compression_size = 0
    api_key_source           = "HEADER"
    endpoint_configuration = {
      types = ["REGIONAL"]
    }
    api_gateway_client_cert_enabled = false
  }

  api_gateway_stages = [
    {
      stage_name        = "prod"
      stage_description = "The stage defined for prod, tied to the default deployment."
    }
  ]
  api_gateway_methods = [
    {
      resource_path = "myPath"

      api_method = {
        settings = {
          metrics_enabled = true
        }
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
        settings = {
          metrics_enabled = true
        }
        authorization = "NONE"
        integration = {
          uri = module.lambda_function.lambda_function_invoke_arn
        }
        http_method = "POST"
      }
    },
    {
      resource_path = "mySecondPath"

      api_method = {
        settings = {
          metrics_enabled = true
        }
        authorization = "NONE"
        integration = {
          uri = module.lambda_function.lambda_function_invoke_arn
        }
        http_method = "GET"
      }
    }
  ]
}
