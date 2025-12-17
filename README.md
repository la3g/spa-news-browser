# SPA News Browser

A Single Page Application (SPA) for browsing news articles with interactive word cloud visualization, powered by AWS Lambda, API Gateway, Route 53, and Google Gemini AI.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
  - [1. Clone/Download Files](#1-clonedownload-files)
  - [2. Configure Environment Variables](#2-configure-environment-variables)
  - [3. Make Scripts Executable](#3-make-scripts-executable)
  - [4. DNS Setup (One-Time)](#4-dns-setup-one-time)
  - [5. Deploy](#5-deploy)
  - [6. Certificate Validation](#6-certificate-validation)
  - [7. Update Your SPA](#7-update-your-spa)
  - [8. Destroy (when needed)](#8-destroy-when-needed)
- [IAM Permissions](#iam-permissions)
  - [Lambda Execution Role Permissions](#1-lambda-execution-role-permissions)
  - [Deployment User/Role Permissions](#2-deployment-userrole-permissions)
  - [AWS Managed Policies](#3-aws-managed-policies-easier-option)
  - [Minimum Required Permissions Summary](#4-minimum-required-permissions-summary)
  - [Security Best Practices](#security-best-practices)
  - [Testing Permissions](#testing-permissions)
  - [Common Permission Issues](#common-permission-issues)
- [Features](#features)
- [Troubleshooting](#troubleshooting)
- [Cost Estimate](#cost-estimate)
- [Architecture](#architecture)
- [Security Notes](#security-notes)
- [Manual Steps](#manual-steps)

## Prerequisites

1. **AWS CLI installed**: [Install AWS CLI](https://aws.amazon.com/cli/)
2. **AWS Profile configured**: `aws configure --profile your-profile-name`
3. **Node.js installed**: Version 18+ (for npm)
4. **Domain configured**: Domain `t.la3g.com` must be delegated to Route 53 (see DNS Setup below)

## Quick Start

### 1. Clone/Download Files

Ensure you have:
- `lambda-function/index.js`
- `lambda-function/package.json`
- `deploy.sh`
- `destroy.sh`
- `.env.example`
- `config.js.example` (copy to `config.js` and fill in your keys)

### 2. Configure Environment Variables

```bash
cp .env.example .env
# Edit .env with your actual values
```

**Backend Configuration (`.env`)** - Used by Lambda function and deployment scripts:
- `GEMINI_API_KEY` - Your Google Gemini API key (for Lambda backend)
- `SUPABASE_URL` - Your Supabase project URL (for Lambda backend)
- `SUPABASE_ANON_KEY` - Your Supabase anonymous key (for Lambda backend)
- `AWS_PROFILE` - Your AWS profile name (optional, can pass as argument)
- `AWS_REGION` - AWS region (optional, defaults to us-east-1)

### 3. Configure Frontend Keys

```bash
cp config.js.example config.js
# Edit config.js with your actual Supabase and Gemini API keys
```

**Frontend Configuration (`config.js`)** - Used by the browser SPA:
- `SUPABASE_URL` - Your Supabase project URL (for frontend direct access)
- `SUPABASE_ANON_KEY` - Your Supabase anonymous key (for frontend direct access)
- `GEMINI_API_KEY` - Your Google Gemini API key (for frontend direct access)

**Why Two Configuration Files?**

- **`.env`** - Used by the **Lambda backend** (server-side). The `deploy.sh` script reads this file and sets these as Lambda environment variables. Lambda functions use `process.env.*` to access these values.

- **`config.js`** - Used by the **browser frontend** (client-side). Browsers cannot read `.env` files, so JavaScript configuration must be in a `.js` file. This allows you to:
  - **Test the frontend locally** without deploying Lambda
  - **Develop and debug** the SPA independently
  - **Use direct API calls** to Gemini and Supabase from the browser

**Note:** In production, you can route all API calls through Lambda (which would only require Supabase keys in `config.js`), but keeping Gemini API key in `config.js` enables local testing and development without Lambda deployment.

### 4. Make Scripts Executable

```bash
chmod +x deploy.sh destroy.sh
```

### 5. DNS Setup (One-Time)

Before deploying, you need to delegate the subdomain to Route 53:

1. **Deploy first** to create the Route 53 hosted zone (see Step 6)
2. **Get Route 53 name servers** from the deployment output
3. **In Namecheap DNS management**:
   - Go to Domain List → Your Domain → Advanced DNS
   - Add 4 NS records:
     - Type: `NS`
     - Host: `t` (just the subdomain part)
     - Value: Each of the 4 Route 53 name servers (one per record)
     - TTL: `Automatic` or `30 min`

**Note:** DNS propagation can take 5-30 minutes. The deployment will create the hosted zone automatically.

### 6. Deploy

```bash
# Using profile from .env file
./deploy.sh

# Or specify profile and region
./deploy.sh my-profile us-east-1
```

The deployment script will:
- Create Lambda function with custom domain support
- Create API Gateway HTTP API
- Create Route 53 hosted zone for `t.la3g.com` (if it doesn't exist)
- Request ACM certificate for `browser.t.la3g.com`
- Automatically add certificate validation records to Route 53
- Create API Gateway custom domain with TLS
- Create Route 53 ALIAS record: `browser.t.la3g.com` → API Gateway custom domain
- Tag all resources with `browser.t.la3g.com` for easy identification
- **Automatically rollback** on failure (deletes created resources)

### 7. Certificate Validation

After deployment, the ACM certificate will be automatically validated via DNS. This typically takes 5-30 minutes. You can check the status:

```bash
aws acm describe-certificate \
    --certificate-arn <ARN_FROM_OUTPUT> \
    --region us-east-1 \
    --profile your-profile
```

The custom domain will work once the certificate status is `ISSUED`.

### 8. Update Your SPA

Copy the **Custom Domain URL** from the deployment output and update your SPA:

```javascript
const LAMBDA_FUNCTION_URL = 'https://browser.t.la3g.com';
```

**Note:** The deployment also creates a Lambda Function URL, but you should use the custom domain URL for production.

### 9. Destroy (when needed)

```bash
./destroy.sh my-profile us-east-1
```

This will remove:
- Lambda Function URL
- Lambda Function
- API Gateway custom domain and mappings
- API Gateway
- Route 53 CNAME/ALIAS record
- IAM Role (if created by this deployment)

**Note:** The Route 53 hosted zone and ACM certificates are preserved (may contain other records/certificates).

## IAM Permissions

### Overview

This section outlines the IAM permissions required to deploy and manage the SPA API Proxy Lambda function with API Gateway and Route 53 custom domain.

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

### Security Best Practices

1. **Least Privilege**: Only grant the minimum permissions needed
2. **Separate Roles**: Use different roles for deployment vs. execution
3. **Environment Variables**: Store sensitive values (API keys) as Lambda environment variables, not in code
4. **Function URL Security**: Consider restricting CORS origins in production
5. **CloudWatch Logs**: Monitor function invocations and errors
6. **Resource Tagging**: All resources are tagged for security and compliance tracking
7. **TLS**: Custom domain uses ACM certificate with automatic renewal
8. **API Gateway**: Uses AWS-managed TLS termination

### Testing Permissions

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

### Common Permission Issues

#### "AccessDenied" when creating Route 53 hosted zone
- Ensure you have `route53:CreateHostedZone` permission
- Check that you have permission to create hosted zones in your account

#### "AccessDenied" when requesting ACM certificate
- Ensure you have `acm:RequestCertificate` permission
- Certificate must be requested in `us-east-1` for API Gateway

#### "AccessDenied" when creating API Gateway custom domain
- Ensure you have `apigatewayv2:CreateDomainName` permission
- Verify the certificate ARN is valid and in `us-east-1`

#### "AccessDenied" when updating Route 53 records
- Ensure you have `route53:ChangeResourceRecordSets` permission
- Verify you have access to the hosted zone

## Features

### Automatic Rollback
If deployment fails at any step, the script automatically:
- Deletes all resources created during this deployment
- Preserves existing resources (only deletes what it created)
- Provides clear error messages
- Cleans up temporary files

### Resource Tagging
All AWS resources are tagged with `Project=browser.t.la3g.com` for:
- Easy identification in AWS Console
- Cost tracking
- Resource organization
- Security and compliance tracking

### Custom Domain with TLS
- **Production URL**: `https://browser.t.la3g.com`
- **TLS Certificate**: Automatically requested and validated via ACM
- **Managed via Route 53**: DNS records automatically configured
- **API Gateway Custom Domain**: Proper TLS termination

### Certificate Management
- Certificate is automatically requested in `us-east-1` (required for API Gateway)
- DNS validation records are automatically added to Route 53
- Certificate validation typically completes in 5-30 minutes
- Certificate is tagged for easy identification

## Troubleshooting

### Permission Denied Errors
- Check [IAM Permissions](#iam-permissions) section for required permissions
- Verify your AWS profile has the necessary access
- Ensure you have Route 53, API Gateway, and ACM permissions

### Function URL Not Working
- Check Lambda function logs in CloudWatch
- Verify environment variables are set correctly
- Check CORS configuration
- Verify API Gateway integration is working

### DNS Not Resolving
- Wait 5-30 minutes for DNS propagation
- Verify NS records are correctly set in Namecheap
- Check Route 53 hosted zone exists and contains the ALIAS record
- Use `dig browser.t.la3g.com` or `nslookup browser.t.la3g.com` to verify

### Certificate Not Validating
- Check certificate status: `aws acm describe-certificate --certificate-arn <ARN> --region us-east-1`
- Verify validation records exist in Route 53
- Wait up to 30 minutes for validation to complete
- Check that the validation CNAME record is correct

### API Gateway Not Working
- Check API Gateway logs in CloudWatch
- Verify Lambda function has permission to be invoked by API Gateway
- Check API Gateway stage is deployed
- Verify custom domain is properly configured
- Check that certificate is validated (Status: ISSUED)

### Custom Domain Not Working
- Verify certificate is validated (Status: ISSUED)
- Check API Gateway custom domain exists
- Verify API mapping is created
- Check Route 53 ALIAS record points to correct target
- Wait for DNS propagation (5-30 minutes)

### Package Too Large
- Lambda has a 50MB limit for direct upload
- For larger packages, use S3 (not needed for this function)

### Deployment Failed - Resources Not Cleaned Up
- Check AWS Console for any remaining resources
- Run `./destroy.sh` manually to clean up
- Resources are tagged with `Project=browser.t.la3g.com` for easy identification
- Check CloudWatch logs for detailed error messages

## Cost Estimate

### Route 53
- Hosted Zone: **$0.50/month** (first 25 zones)
- DNS Queries: **$0.40 per million** (first billion/month)
- **Typical monthly cost**: ~$0.50-1.00/month

### API Gateway
- HTTP API: **Free** (first 1 million requests/month)
- Custom Domain: **Free**
- **Typical monthly cost**: $0/month (within free tier)

### Lambda
- Function: **Free** (first 1 million requests/month)
- **Typical monthly cost**: $0/month (within free tier)

### ACM
- Certificate: **Free**
- **Typical monthly cost**: $0/month

**Total estimated cost**: ~$0.50-1.00/month (or free if within AWS Free Tier)

## Architecture

```
SPA (Browser)
    ↓ HTTPS (TLS)
browser.t.la3g.com (Route 53 ALIAS)
    ↓
API Gateway Custom Domain (TLS Termination)
    ↓
API Gateway HTTP API
    ↓ AWS_PROXY
Lambda Function
    ↓ HTTPS
Gemini API / Supabase
```

## Security Notes

1. **CORS**: Currently configured to allow all origins (`*`). Consider restricting in production.
2. **Function URL**: Created but not used in production (custom domain is preferred).
3. **Environment Variables**: Sensitive keys stored as Lambda environment variables.
4. **IAM Roles**: Least privilege principle applied.
5. **Resource Tagging**: All resources tagged for security and compliance tracking.
6. **TLS**: Custom domain uses ACM certificate with automatic renewal.
7. **API Gateway**: Uses AWS-managed TLS termination.

## Manual Steps

### If Certificate Validation Fails

If automatic validation doesn't work, you can manually add the validation record:

1. Get validation details:
```bash
aws acm describe-certificate \
    --certificate-arn <CERT_ARN> \
    --region us-east-1 \
    --profile your-profile
```

2. Add the CNAME record shown in the output to Route 53 manually.

### Verify Deployment

```bash
# Check Lambda function
aws lambda get-function --function-name spa-api-proxy --profile your-profile --region us-east-1

# Check API Gateway
aws apigatewayv2 get-apis --profile your-profile --region us-east-1

# Check Route 53 records
aws route53 list-resource-record-sets \
    --hosted-zone-id <ZONE_ID> \
    --profile your-profile

# Check certificate status
aws acm describe-certificate \
    --certificate-arn <CERT_ARN> \
    --region us-east-1 \
    --profile your-profile
```

