resource aws_lb_target_group "this" {

    for_each = { for tg in var.target_groups: tg.name => tg } 

    name = each.key

    ## Network Load Balancers do not support the lambda target type.
    ## Application Load Balancers do not support the alb target type.
    target_type = lookup(each.value, "target_type", "instance")

    vpc_id      = var.vpc_id
    port        = local.gateway ? 6081 : lookup(each.value, "port", null)
    protocol    = local.gateway ? "GENEVE" : (
                        (lookup(each.value, "target_type", "instance") != "lambda") ? lookup(each.value, "protocol", "HTTP") : null)
    protocol_version = ((lookup(each.value, "target_type", "instance") != "lambda") && 
                            (lookup(each.value, "protocol", "HTTP") == "HTTP" || 
                                (lookup(each.value, "protocol", "HTTP") == "HTTPS"))) ? lookup(each.value, "protocol_version", "HTTP1") : null

    connection_termination = lookup(each.value, "connection_termination", false)
    deregistration_delay = lookup(each.value, "deregistration_delay", 300)
    load_balancing_algorithm_type = local.alb ? lookup(each.value, "load_balancing_algorithm_type", "round_robin") : null
    preserve_client_ip = lookup(each.value, "preserve_client_ip", null)
    proxy_protocol_v2 = local.nlb ? lookup(each.value, "proxy_protocol_v2", false) : null
    slow_start = lookup(each.value, "slow_start", 0)

    lambda_multi_value_headers_enabled = (lookup(each.value, "target_type", "instance") == "lambda") ? lookup(each.value, "lambda_multi_value_headers_enabled", false) : null
  
    dynamic "health_check" {
        for_each = (length(keys(lookup(each.value, "health_check", {}))) > 0) ? [1] : []

        content {
            enabled             = lookup(each.value.health_check, "enabled", true)
            protocol            = (lookup(each.value, "target_type", "instance") != "lambda") ? lookup(each.value.health_check, "protocol", "HTTP") : null
            path                = lookup(each.value.health_check, "path", null)
            port                = lookup(each.value.health_check, "port", "traffic-port")
            interval            = lookup(each.value.health_check, "interval", 30)
            healthy_threshold   = lookup(each.value.health_check, "healthy_threshold", 3)
            unhealthy_threshold = local.nlb ? lookup(each.value.health_check, "healthy_threshold", 3) : lookup(each.value.health_check, "unhealthy_threshold", 3)
            timeout             = lookup(each.value.health_check, "timeout", null)
            matcher             = local.alb ? lookup(each.value.health_check, "matcher", null) : null
        }
    }

    dynamic "stickiness" {
        for_each = (length(keys(lookup(each.value, "stickiness", {}))) > 0) ? [1] : []

        content {
            enabled             = lookup(each.value.stickiness, "enabled", true)
            type                = each.value.stickiness.type
            cookie_name         = (lookup(each.value.stickiness, "type", "") == "app_cookie") ? lookup(each.value.stickiness, "cookie_name", null) : null
            cookie_duration     = (lookup(each.value.stickiness, "type", "") == "lb_cookie") ? lookup(each.value.stickiness, "cookie_duration", 86400 ) : null
        }
    }

    tags = local.gateway ? null : merge( { "Name" = format("%s.%s", var.name, each.key) }, 
                                                { "LoadBalancer" = var.name }, var.default_tags )

}

## Allow Target Groups (which are of type `lambda`) to invoke Lamnda Functions 
resource aws_lambda_permission "this" {
    for_each = { for k, v in local.lambda_targets : k => v }

    statement_id = "AllowExecutionFromLoadBalancer"
    
    action      = "lambda:InvokeFunction"
    principal   = "elasticloadbalancing.amazonaws.com"

    function_name = each.value.function_details[6]
    qualifier     = try(each.value.function_details[7], null)
    
    source_arn = aws_lb_target_group.this[each.value.tg_name].arn
}

## Targets Registration
resource aws_lb_target_group_attachment "this" {
    for_each = local.targets

    target_group_arn  = aws_lb_target_group.this[each.value.tg_name].arn
    target_id         = each.value.target_id
    port              = lookup(each.value, "port", null)
    availability_zone = lookup(each.value, "availability_zone", null)

    depends_on = [
      aws_lambda_permission.this
    ]
}
