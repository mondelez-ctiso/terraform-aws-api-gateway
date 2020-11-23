terraform {
  required_version = "~> 0.13"
  required_providers {
    aws = "~> 3.0"
  }
}

provider "aws" {}

locals {

  ##################
  ## Set defaults ##
  ##################

  // api_gateway
  api_gateway = merge(var.api_gateway_default, var.api_gateway)

  // api_gateway_deployment defaults
  api_gateway_deployment = var.api_gateway_deployment != null ? merge(var.api_gateway_deployment_default, var.api_gateway_deployment) : null

  // api_gateway_stages defaults
  api_gateway_stages = var.api_gateway_stages != null ? [for stage in var.api_gateway_stages : merge(var.api_gateway_stage_default, stage)] : null

  // api_gateway_models defaults
  api_gateway_models = var.api_gateway_models != null ? [for model in var.api_gateway_models : merge(var.api_gateway_model_default, model)] : null

  // api_keys
  api_keys = var.api_keys != null ? [for api_key in var.api_keys : merge(var.api_keys_default, api_key)] : null

  // vpc_links
  vpc_links = var.vpc_links != null ? [for vpc_link in var.vpc_links : merge(var.vpc_link_default, vpc_link)] : null

  // authorizer_definitions
  authorizer_definitions = var.authorizer_definitions != null ? [for auth in var.authorizer_definitions : merge(var.authorizer_definition_default, auth)] : null

  // api_gateway_methods
  api_gateway_methods = [for method in var.api_gateway_methods :
    merge(method,
      { api_method = merge(
        var.api_gateway_method_default,
        try(method.api_method, {}),
        try({ integration = merge(var.method_integration_default, method.api_method.integration) }, { integration = var.method_integration_default }),
        try({ integration_response = merge(var.method_integration_response_default, method.api_method.integration_response) }, { integration_response = var.method_integration_response_default }),
        try({ response = merge(var.method_response_default, method.api_method.response) }, { response = var.method_response_default }),
      ) },
      { options_method = merge(
        var.api_gateway_options_default,
        try(method.options_method, {}),
        try({ integration = merge(var.options_integration_default, method.options_method.integration) }, { integration = var.options_integration_default }),
        try({ integration_response = merge(var.options_integration_response_default, method.options_method.integration_response) }, { integration_response = var.options_integration_response_default }),
        try({ response = merge(var.options_response_default, method.options_method.response) }, { response = var.options_response_default }),
      ) },
  )]

  ###########################
  ## Resource path parsing ##
  ###########################

  paths = [for method in local.api_gateway_methods : method.resource_path]

  paths_as_segments = [for path in local.paths : split("/", path)]

  unique_paths = (toset(
    flatten(
      [for path_segments in local.paths_as_segments :
        [for end_index in range(length(path_segments), 0) :
  join("/", slice(path_segments, 0, end_index))]])))

  length_paths_map = (transpose({ for path in local.unique_paths : path => [length(split("/", path))] }))

  length_path_segments_map = ({ for quantity, paths in local.length_paths_map : quantity => [for path in paths : split("/", path)] })

  max_number_of_levels = can(local.length_path_segments_map) ? length(local.length_path_segments_map) : 0

  resource_method_map = (
    merge(
      local.max_number_of_levels > 0 ? zipmap(flatten(local.length_paths_map[1]), values(aws_api_gateway_resource.first_paths)[*]["id"]) : {},
      local.max_number_of_levels > 1 ? zipmap(flatten(local.length_paths_map[2]), values(aws_api_gateway_resource.second_paths)[*]["id"]) : {},
      local.max_number_of_levels > 2 ? zipmap(flatten(local.length_paths_map[3]), values(aws_api_gateway_resource.third_paths)[*]["id"]) : {},
      local.max_number_of_levels > 3 ? zipmap(flatten(local.length_paths_map[4]), values(aws_api_gateway_resource.fourth_paths)[*]["id"]) : {},
      local.max_number_of_levels > 4 ? zipmap(flatten(local.length_paths_map[5]), values(aws_api_gateway_resource.fifth_paths)[*]["id"]) : {}
    )
  )

  ###################################
  ## Authorizor name to ID mapping ##
  ###################################
  authorizers = zipmap([for auth in local.authorizer_definitions : auth.authorizer_name], aws_api_gateway_authorizer.default[*]["id"])
}

# Resource    : API Gateway 
# Description : Terraform resource to create an API Gateway REST API on AWS.
resource aws_api_gateway_rest_api default {
  count = var.enabled ? 1 : 0

  api_key_source           = local.api_gateway.api_key_source
  binary_media_types       = local.api_gateway.binary_media_types
  description              = local.api_gateway.description
  minimum_compression_size = local.api_gateway.minimum_compression_size
  name                     = local.api_gateway.name
  policy                   = local.api_gateway.policy

  dynamic endpoint_configuration {
    for_each = local.api_gateway.endpoint_configuration == null ? [] : [local.api_gateway.endpoint_configuration]
    content {
      types            = endpoint_configuration.value.types
      vpc_endpoint_ids = lookup(endpoint_configuration.value, "vpc_endpoint_ids", null)
    }
  }

  tags = var.tags
}

# Resource    : Api Gateway Client Certificate
# Description : Terraform resource to create Api Gateway Client Certificate on AWS.
resource aws_api_gateway_client_certificate default {
  count = local.api_gateway.client_cert_enabled == true ? 1 : 0

  description = local.api_gateway.client_cert_description
  tags        = var.tags
}

# Resource    : Api Gateway Custom Domain Name
# Description : Terraform resource to create Api Gateway Custom Domain on AWS.
resource aws_api_gateway_domain_name api_domain {
  count = local.api_gateway.custom_domain != null ? 1 : 0

  certificate_arn = local.api_gateway.acm_cert_arn
  domain_name     = local.api_gateway.custom_domain
}

# Resource    : Api Gateway Base Path Mapping
# Description : Terraform resource to create Api Gateway base path mapping on AWS.
resource aws_api_gateway_base_path_mapping mapping {
  count = local.api_gateway.custom_domain != null ? 1 : 0

  api_id      = aws_api_gateway_rest_api.default.*.id[0]
  stage_name  = local.api_gateway.base_path_mapping_active_stage_name
  domain_name = local.api_gateway.custom_domain

  depends_on = [aws_api_gateway_deployment.default, aws_api_gateway_stage.default]
}

# Resource    : DNS record using Route53.
# Description : Route53 is not specifically required; any DNS host can be used.
resource aws_route53_record api_dns {
  count   = local.api_gateway.custom_domain != null ? 1 : 0
  name    = aws_api_gateway_domain_name.api_domain.*.domain_name[0]
  type    = "A"
  zone_id = local.api_gateway.hosted_zone_id

  alias {
    evaluate_target_health = true
    name                   = aws_api_gateway_domain_name.api_domain.*.cloudfront_domain_name[0]
    zone_id                = aws_api_gateway_domain_name.api_domain.*.cloudfront_zone_id[0]
  }
}

# Resource    : Api Gateway Deployment
# Description : Terraform resource to create Api Gateway Deployment on AWS.
resource aws_api_gateway_deployment default {
  count = local.api_gateway.default_deployment_name != null ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  stage_name  = local.api_gateway.default_deployment_name
  description = local.api_gateway.default_deployment_description
  # variables         = local.api_gateway_deployment.variables

  depends_on = [aws_api_gateway_method.default, aws_api_gateway_integration.default]
}

# Resource    : Api Gateway Stage
# Description : Terraform resource to create Api Gateway Stage on AWS
resource aws_api_gateway_stage default {
  count = length(local.api_gateway_stages)

  rest_api_id           = aws_api_gateway_rest_api.default.*.id[0]
  deployment_id         = aws_api_gateway_deployment.default.*.id[0]
  stage_name            = element(local.api_gateway_stages, count.index).stage_name
  cache_cluster_enabled = element(local.api_gateway_stages, count.index).cache_cluster_enabled
  cache_cluster_size    = element(local.api_gateway_stages, count.index).cache_cluster_size
  client_certificate_id = element(local.api_gateway_stages, count.index).client_certificate_id != null ? element(local.api_gateway_stages, count.index).client_certificate_id : (local.api_gateway.client_cert_enabled ? aws_api_gateway_client_certificate.default.*.id[0] : "")
  description           = element(local.api_gateway_stages, count.index).stage_description
  documentation_version = element(local.api_gateway_stages, count.index).documentation_version
  variables             = element(local.api_gateway_stages, count.index).stage_variables
  xray_tracing_enabled  = element(local.api_gateway_stages, count.index).xray_tracing_enabled

  dynamic "access_log_settings" {
    for_each = lookup(element(local.api_gateway_stages, count.index), "access_log_settings")
    content {
      destination_arn = access_log_settings.value["destination_arn"]
      format          = access_log_settings.value["format"]
    }
  }

  tags = var.tags
}

# Resource    : Api Gateway Model
# Description : Terraform resource to create Api Gateway model on AWS.
resource aws_api_gateway_model default {
  count = length(local.api_gateway_models)

  rest_api_id  = aws_api_gateway_rest_api.default.*.id[0]
  name         = element(local.api_gateway_models, count.index).name
  description  = element(local.api_gateway_models, count.index).description
  content_type = element(local.api_gateway_models, count.index).content_type
  schema       = element(local.api_gateway_models, count.index).schema
}

# Resource    : Api Gateway Api Key
# Description : Terraform resource to create Api Gateway Api Key on AWS.
resource aws_api_gateway_api_key default {
  count = length(local.api_keys)

  name        = element(local.api_keys, count.index).key_name
  description = length(element(local.api_keys, count.index).key_description) > 0 ? element(local.api_keys, count.index).key_description : ""
  enabled     = element(local.api_keys, count.index).enabled
  value       = length(element(local.api_keys, count.index).value) > 0 ? element(local.api_keys, count.index).value : null

  tags = var.tags
}

# Resource    : Api Gateway VPC Link
# Description : Terraform resource to create Api Gateway VPC Link on AWS.
resource aws_api_gateway_vpc_link default {
  count = length(local.vpc_links)

  name        = element(local.vpc_links, count.index).vpc_link_name
  description = length(element(local.vpc_links, count.index).vpc_link_description) > 0 ? element(local.vpc_links, count.index).vpc_link_description : ""
  target_arns = element(local.vpc_links, count.index).target_arns

  tags = var.tags
}

# Resource    : Api Gateway Authorizer
# Description : Terraform resource to create Api Gateway Authorizer on AWS.
resource aws_api_gateway_authorizer default {
  count = length(local.authorizer_definitions)

  rest_api_id                      = aws_api_gateway_rest_api.default.*.id[0]
  name                             = element(local.authorizer_definitions, count.index).authorizer_name
  authorizer_uri                   = element(local.authorizer_definitions, count.index).authorizer_uri
  authorizer_credentials           = element(local.authorizer_definitions, count.index).authorizer_credentials
  authorizer_result_ttl_in_seconds = element(local.authorizer_definitions, count.index).authorizer_result_ttl_in_seconds
  identity_source                  = element(local.authorizer_definitions, count.index).identity_source
  type                             = element(local.authorizer_definitions, count.index).authorizer_type
  identity_validation_expression   = element(local.authorizer_definitions, count.index).identity_validation_expression
  provider_arns                    = element(local.authorizer_definitions, count.index).provider_arns
}

# Resource    : Api Gateway Resources (curently supporting up to 5 nested levels)
# Description : Terraform resource to create Api Gateway Resources on AWS
resource aws_api_gateway_resource first_paths {
  for_each = local.max_number_of_levels > 0 ? toset(flatten(local.length_path_segments_map[1])) : []

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  parent_id   = aws_api_gateway_rest_api.default.*.root_resource_id[0]
  path_part   = each.value
}

resource aws_api_gateway_resource second_paths {
  for_each = local.max_number_of_levels > 1 ? { for path in local.length_path_segments_map[2] : join("/", path) => { segment = path[1], parent = join("/", slice(path, 0, 1)) } } : {}

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  parent_id   = aws_api_gateway_resource.first_paths[each.value.parent].id
  path_part   = each.value.segment
}

resource aws_api_gateway_resource third_paths {
  for_each = local.max_number_of_levels > 2 ? { for path in local.length_path_segments_map[3] : join("/", path) => { segment = path[2], parent = join("/", slice(path, 0, 2)) } } : {}

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  parent_id   = aws_api_gateway_resource.second_paths[each.value.parent].id
  path_part   = each.value.segment
}

resource aws_api_gateway_resource fourth_paths {
  for_each = local.max_number_of_levels > 3 ? { for path in local.length_path_segments_map[4] : join("/", path) => { segment = path[3], parent = join("/", slice(path, 0, 3)) } } : {}

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  parent_id   = aws_api_gateway_resource.third_paths[each.value.parent].id
  path_part   = each.value.segment
}

resource aws_api_gateway_resource fifth_paths {
  for_each = local.max_number_of_levels > 4 ? { for path in local.length_path_segments_map[5] : join("/", path) => { segment = path[4], parent = join("/", slice(path, 0, 4)) } } : {}

  rest_api_id = aws_api_gateway_rest_api.default.*.id[0]
  parent_id   = aws_api_gateway_resource.fourth_paths[each.value.parent].id
  path_part   = each.value.segment
}

########################
## API Gateway Method ##
########################

# Resource    : Api Gateway Method
# Description : Terraform resource to create Api Gateway Method on AWS.
resource aws_api_gateway_method default {
  count = length(local.api_gateway_methods)

  rest_api_id          = aws_api_gateway_rest_api.default.*.id[0]
  resource_id          = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method          = element(local.api_gateway_methods, count.index).api_method.http_method
  authorization        = element(local.api_gateway_methods, count.index).api_method.authorization
  authorizer_id        = element(local.api_gateway_methods, count.index).api_method.authorizer_id != null ? element(local.api_gateway_methods, count.index).api_method.authorizer_id : element(local.api_gateway_methods, count.index).api_method.authorizer_name != null ? lookup(local.authorizers, element(local.api_gateway_methods, count.index).api_method.authorizer_name, null) : null
  authorization_scopes = element(local.api_gateway_methods, count.index).api_method.authorization_scopes
  api_key_required     = element(local.api_gateway_methods, count.index).api_method.api_key_required
  request_models       = element(local.api_gateway_methods, count.index).api_method.request_models
  request_validator_id = element(local.api_gateway_methods, count.index).api_method.request_validator_id
  request_parameters   = element(local.api_gateway_methods, count.index).api_method.request_parameters
}

# Resource    : Api Gateway Method Response
# Description : Terraform resource to create Api Gateway Method Response on AWS.
resource aws_api_gateway_method_response default {
  count = length(local.api_gateway_methods)

  rest_api_id         = aws_api_gateway_rest_api.default.*.id[0]
  resource_id         = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method         = element(local.api_gateway_methods, count.index).api_method.http_method
  status_code         = element(local.api_gateway_methods, count.index).api_method.response.status_code
  response_models     = element(local.api_gateway_methods, count.index).api_method.response.response_models
  response_parameters = element(local.api_gateway_methods, count.index).api_method.response.response_parameters

  depends_on = [aws_api_gateway_method.default]
}

# Resource    : Api Gateway Integration
# Description : Terraform resource to create Api Gateway Integration on AWS.
resource aws_api_gateway_integration default {
  count = length(local.api_gateway_methods)

  rest_api_id             = aws_api_gateway_rest_api.default.*.id[0]
  resource_id             = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method             = element(local.api_gateway_methods, count.index).api_method.http_method
  integration_http_method = element(local.api_gateway_methods, count.index).api_method.integration.integration_http_method
  type                    = element(local.api_gateway_methods, count.index).api_method.integration.type
  connection_type         = element(local.api_gateway_methods, count.index).api_method.integration.connection_type
  connection_id           = element(local.api_gateway_methods, count.index).api_method.integration.connection_id
  uri                     = element(local.api_gateway_methods, count.index).api_method.integration.uri
  credentials             = element(local.api_gateway_methods, count.index).api_method.integration.credentials
  request_parameters      = element(local.api_gateway_methods, count.index).api_method.integration.request_parameters
  request_templates       = element(local.api_gateway_methods, count.index).api_method.integration.request_templates
  passthrough_behavior    = element(local.api_gateway_methods, count.index).api_method.integration.passthrough_behavior
  cache_key_parameters    = element(local.api_gateway_methods, count.index).api_method.integration.cache_key_parameters
  cache_namespace         = element(local.api_gateway_methods, count.index).api_method.integration.cache_namespace
  content_handling        = element(local.api_gateway_methods, count.index).api_method.integration.content_handling
  timeout_milliseconds    = element(local.api_gateway_methods, count.index).api_method.integration.timeout_milliseconds

  depends_on = [aws_api_gateway_method.default]
}

# Resource    : Api Gateway Integration Response
# Description : Terraform resource to create Api Gateway Integration Response on AWS for creating api.
resource aws_api_gateway_integration_response default {
  count               = length(local.api_gateway_methods)
  rest_api_id         = aws_api_gateway_rest_api.default.*.id[0]
  resource_id         = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method         = element(local.api_gateway_methods, count.index).api_method.http_method
  status_code         = element(local.api_gateway_methods, count.index).api_method.integration_response.status_code
  response_parameters = element(local.api_gateway_methods, count.index).api_method.integration_response.response_parameters
  response_templates  = element(local.api_gateway_methods, count.index).api_method.integration_response.response_template
  content_handling    = element(local.api_gateway_methods, count.index).api_method.integration_response.content_handling
  selection_pattern   = element(local.api_gateway_methods, count.index).api_method.integration_response.selection_pattern

  depends_on = [
    aws_api_gateway_integration.default,
  ]
}

####################
## Options Method ##
####################

# Resource    : Api Gateway Options Method
# Description : Terraform resource to create Api Gateway Options Method on AWS.
resource aws_api_gateway_method options_method {
  count = length(local.api_gateway_methods)

  rest_api_id          = aws_api_gateway_rest_api.default.*.id[0]
  resource_id          = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method          = element(local.api_gateway_methods, count.index).options_method.http_method
  authorization        = element(local.api_gateway_methods, count.index).options_method.authorization
  authorizer_id        = element(local.api_gateway_methods, count.index).options_method.authorizer_id != null ? element(local.api_gateway_methods, count.index).options_method.authorizer_id : element(local.api_gateway_methods, count.index).options_method.authorizer_name != null ? lookup(local.authorizers, element(local.api_gateway_methods, count.index).options_method.authorizer_name, null) : null
  authorization_scopes = element(local.api_gateway_methods, count.index).options_method.authorization_scopes
  api_key_required     = element(local.api_gateway_methods, count.index).options_method.api_key_required
  request_models       = element(local.api_gateway_methods, count.index).options_method.request_models
  request_validator_id = element(local.api_gateway_methods, count.index).options_method.request_validator_id
  request_parameters   = element(local.api_gateway_methods, count.index).options_method.request_parameters
}

# Resource    : Api Gateway Method Options Response
# Description : Terraform resource to create Api Gateway Method Options Response on AWS.
resource aws_api_gateway_method_response options_200 {
  count = length(local.api_gateway_methods)

  rest_api_id         = aws_api_gateway_rest_api.default.*.id[0]
  resource_id         = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method         = element(local.api_gateway_methods, count.index).options_method.http_method
  status_code         = element(local.api_gateway_methods, count.index).options_method.response.status_code
  response_models     = element(local.api_gateway_methods, count.index).options_method.response.response_models
  response_parameters = element(local.api_gateway_methods, count.index).options_method.response.response_parameters

  depends_on = [aws_api_gateway_method.options_method]
}

# Resource    : Api Gateway Options Integration
# Description : Terraform resource to create Api Gateway Options Integration on AWS.
resource aws_api_gateway_integration options_integration {
  count                   = length(local.api_gateway_methods)
  rest_api_id             = aws_api_gateway_rest_api.default.*.id[0]
  resource_id             = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method             = element(local.api_gateway_methods, count.index).options_method.http_method
  integration_http_method = element(local.api_gateway_methods, count.index).options_method.integration.integration_http_method
  type                    = element(local.api_gateway_methods, count.index).options_method.integration.type
  connection_type         = element(local.api_gateway_methods, count.index).options_method.integration.connection_type
  connection_id           = element(local.api_gateway_methods, count.index).options_method.integration.connection_id
  uri                     = element(local.api_gateway_methods, count.index).options_method.integration.uri
  credentials             = element(local.api_gateway_methods, count.index).options_method.integration.credentials
  request_parameters      = element(local.api_gateway_methods, count.index).options_method.integration.request_parameters
  request_templates       = element(local.api_gateway_methods, count.index).options_method.integration.request_templates
  passthrough_behavior    = element(local.api_gateway_methods, count.index).options_method.integration.passthrough_behavior
  cache_key_parameters    = element(local.api_gateway_methods, count.index).options_method.integration.cache_key_parameters
  cache_namespace         = element(local.api_gateway_methods, count.index).options_method.integration.cache_namespace
  content_handling        = element(local.api_gateway_methods, count.index).options_method.integration.content_handling
  timeout_milliseconds    = element(local.api_gateway_methods, count.index).options_method.integration.timeout_milliseconds

  depends_on = [aws_api_gateway_method.options_method]
}

# Resource    : Api Gateway Integration Response
# Description : Terraform resource to create Api Gateway Integration Response on AWS for creating api.
resource aws_api_gateway_integration_response options_integration_response {
  count               = length(aws_api_gateway_integration.options_integration.*.id)
  rest_api_id         = aws_api_gateway_rest_api.default.*.id[0]
  resource_id         = lookup(local.resource_method_map, element(local.api_gateway_methods, count.index).resource_path)
  http_method         = element(local.api_gateway_methods, count.index).options_method.http_method
  status_code         = element(local.api_gateway_methods, count.index).options_method.integration_response.status_code
  response_parameters = element(local.api_gateway_methods, count.index).options_method.integration_response.response_parameters
  response_templates  = element(local.api_gateway_methods, count.index).options_method.integration_response.response_template
  content_handling    = element(local.api_gateway_methods, count.index).options_method.integration_response.content_handling
  selection_pattern   = element(local.api_gateway_methods, count.index).options_method.integration_response.selection_pattern

  depends_on = [
    aws_api_gateway_integration.options_integration,
  ]
}