# IAM Permissions Required

## Overview
This document outlines the IAM permissions required to deploy and manage the SPA API Proxy Lambda function with API Gateway and Route 53 custom domain.

## Required Permissions

### 1. Lambda Execution Role Permissions

The Lambda execution role (`lambda-execution-role-spa`) needs the following permissions:

#### Basic Lambda Execution (Required)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:*:*:*"
    }
  ]
}
```

**Note:** This is automatically attached via the AWS managed policy:
- `arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole`

#### No Additional Permissions Required
The Lambda function only needs to:
- Write CloudWatch logs (handled by basic execution role)
- Make outbound HTTPS calls to Gemini API and Supabase (no special permissions needed)

### 2. Deployment User/Role Permissions

The AWS profile/user running the deployment scripts needs these permissions:

#### Lambda Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction",
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction",
        "lambda:DeleteFunction",
        "lambda:CreateFunctionUrlConfig",
        "lambda:GetFunctionUrlConfig",
        "lambda:DeleteFunctionUrlConfig",
        "lambda:AddPermission",
        "lambda:GetPolicy",
        "lambda:RemovePermission",
        "lambda:TagResource",
        "lambda:UntagResource",
        "lambda:ListTags"
      ],
      "Resource": "arn:aws:lambda:*:*:function:spa-api-proxy"
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:ListFunctions"
      ],
      "Resource": "*"
    }
  ]
}
```

#### IAM Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:ListAttachedRolePolicies",
        "iam:ListRolePolicies",
        "iam:DeleteRolePolicy",
        "iam:PassRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRoleTags"
      ],
      "Resource": [
        "arn:aws:iam::*:role/lambda-execution-role-spa"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy"
      ],
      "Resource": "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
    }
  ]
}
```

#### API Gateway Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "apigatewayv2:CreateApi",
        "apigatewayv2:GetApi",
        "apigatewayv2:UpdateApi",
        "apigatewayv2:DeleteApi",
        "apigatewayv2:ListApis",
        "apigatewayv2:CreateIntegration",
        "apigatewayv2:GetIntegration",
        "apigatewayv2:UpdateIntegration",
        "apigatewayv2:DeleteIntegration",
        "apigatewayv2:CreateRoute",
        "apigatewayv2:GetRoute",
        "apigatewayv2:UpdateRoute",
        "apigatewayv2:DeleteRoute",
        "apigatewayv2:CreateStage",
        "apigatewayv2:GetStage",
        "apigatewayv2:UpdateStage",
        "apigatewayv2:DeleteStage",
        "apigatewayv2:CreateDomainName",
        "apigatewayv2:GetDomainName",
        "apigatewayv2:UpdateDomainName",
        "apigatewayv2:DeleteDomainName",
        "apigatewayv2:ListDomainNames",
        "apigatewayv2:CreateApiMapping",
        "apigatewayv2:GetApiMapping",
        "apigatewayv2:UpdateApiMapping",
        "apigatewayv2:DeleteApiMapping",
        "apigatewayv2:GetApiMappings",
        "apigatewayv2:TagResource",
        "apigatewayv2:UntagResource",
        "apigatewayv2:GetTags"
      ],
      "Resource": "*"
    }
  ]
}
```

#### Route 53 Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "route53:CreateHostedZone",
        "route53:GetHostedZone",
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets",
        "route53:GetChange",
        "route53:ChangeTagsForResource",
        "route53:ListTagsForResource"
      ],
      "Resource": "*"
    }
  ]
}
```

#### ACM (Certificate Manager) Permissions
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "acm:RequestCertificate",
        "acm:DescribeCertificate",
        "acm:ListCertificates",
        "acm:AddTagsToCertificate",
        "acm:RemoveTagsFromCertificate",
        "acm:ListTagsForCertificate"
      ],
      "Resource": "*"
    }
  ]
}
```

#### STS Permissions (to get account ID)
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### 3. AWS Managed Policies (Easier Option)

Instead of creating custom policies, you can attach these AWS managed policies:

#### For Deployment User:
- `AWSLambda_FullAccess` - Full Lambda management
- `IAMFullAccess` - Full IAM management (or create custom policy above)
- `AmazonAPIGatewayAdministrator` - Full API Gateway management
- `AmazonRoute53FullAccess` - Full Route 53 management
- `AmazonS3ReadOnlyAccess` - If using S3 for deployment packages (optional)

**Note:** These managed policies are very permissive. For production, create custom policies with only the permissions listed above.

### 4. Minimum Required Permissions Summary

**Lambda Execution Role:**
- CloudWatch Logs write access (via `AWSLambdaBasicExecutionRole`)

**Deployment User:**
- Lambda: Create, Read, Update, Delete functions and function URLs; Tag resources
- IAM: Create, Read, Delete roles; Attach/Detach policies; PassRole; Tag roles
- STS: GetCallerIdentity
- API Gateway: Full management of HTTP APIs, integrations, routes, stages, custom domains, and API mappings; Tag resources
- Route 53: Create/Manage hosted zones and DNS records; Tag resources
- ACM: Request and manage certificates; Tag resources

## Security Best Practices

1. **Least Privilege**: Only grant the minimum permissions needed
2. **Separate Roles**: Use different roles for deployment vs. execution
3. **Environment Variables**: Store sensitive values (API keys) as Lambda environment variables, not in code
4. **Function URL Security**: Consider restricting CORS origins in production
5. **CloudWatch Logs**: Monitor function invocations and errors
6. **Resource Tagging**: All resources are tagged for security and compliance tracking
7. **TLS**: Custom domain uses ACM certificate with automatic renewal
8. **API Gateway**: Uses AWS-managed TLS termination

## Testing Permissions

To test if your user has the required permissions:

```bash
# Test Lambda permissions
aws lambda list-functions --profile your-profile

# Test IAM permissions
aws iam get-role --role-name lambda-execution-role-spa --profile your-profile

# Test STS permissions
aws sts get-caller-identity --profile your-profile

# Test API Gateway permissions
aws apigatewayv2 get-apis --profile your-profile --region us-east-1

# Test Route 53 permissions
aws route53 list-hosted-zones --profile your-profile

# Test ACM permissions
aws acm list-certificates --region us-east-1 --profile your-profile
```

If any of these commands fail, you may need additional permissions.

## Common Permission Issues

### "AccessDenied" when creating Route 53 hosted zone
- Ensure you have `route53:CreateHostedZone` permission
- Check that you have permission to create hosted zones in your account

### "AccessDenied" when requesting ACM certificate
- Ensure you have `acm:RequestCertificate` permission
- Certificate must be requested in `us-east-1` for API Gateway

### "AccessDenied" when creating API Gateway custom domain
- Ensure you have `apigatewayv2:CreateDomainName` permission
- Verify the certificate ARN is valid and in `us-east-1`

### "AccessDenied" when updating Route 53 records
- Ensure you have `route53:ChangeResourceRecordSets` permission
- Verify you have access to the hosted zone
