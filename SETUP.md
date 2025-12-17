# Setup Instructions

## Prerequisites

1. **AWS CLI installed**: [Install AWS CLI](https://aws.amazon.com/cli/)
2. **AWS Profile configured**: `aws configure --profile your-profile-name`
3. **Node.js installed**: Version 18+ (for npm)
4. **IAM Permissions**: See `IAM_PERMISSIONS.md`
5. **Domain configured**: Domain `t.la3g.com` must be delegated to Route 53 (see DNS Setup below)

## Quick Start

### 1. Clone/Download Files

Ensure you have:
- `lambda-function/index.js`
- `lambda-function/package.json`
- `deploy.sh`
- `destroy.sh`
- `.env.example`

### 2. Configure Environment Variables

```bash
cp .env.example .env
# Edit .env with your actual values
```

Required variables:
- `GEMINI_API_KEY` - Your Google Gemini API key
- `SUPABASE_URL` - Your Supabase project URL
- `SUPABASE_ANON_KEY` - Your Supabase anonymous key
- `AWS_PROFILE` - Your AWS profile name (optional, can pass as argument)
- `AWS_REGION` - AWS region (optional, defaults to us-east-1)

### 3. Make Scripts Executable

```bash
chmod +x deploy.sh destroy.sh
```

### 4. DNS Setup (One-Time)

Before deploying, you need to delegate the subdomain to Route 53:

1. **Deploy first** to create the Route 53 hosted zone (see Step 5)
2. **Get Route 53 name servers** from the deployment output
3. **In Namecheap DNS management**:
   - Go to Domain List → Your Domain → Advanced DNS
   - Add 4 NS records:
     - Type: `NS`
     - Host: `t` (just the subdomain part)
     - Value: Each of the 4 Route 53 name servers (one per record)
     - TTL: `Automatic` or `30 min`

**Note:** DNS propagation can take 5-30 minutes. The deployment will create the hosted zone automatically.

### 5. Deploy

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

### 6. Certificate Validation

After deployment, the ACM certificate will be automatically validated via DNS. This typically takes 5-30 minutes. You can check the status:

```bash
aws acm describe-certificate \
    --certificate-arn <ARN_FROM_OUTPUT> \
    --region us-east-1 \
    --profile your-profile
```

The custom domain will work once the certificate status is `ISSUED`.

### 7. Update Your SPA

Copy the **Custom Domain URL** from the deployment output and update your SPA:

```javascript
const LAMBDA_FUNCTION_URL = 'https://browser.t.la3g.com';
```

**Note:** The deployment also creates a Lambda Function URL, but you should use the custom domain URL for production.

### 8. Destroy (when needed)

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
- Check `IAM_PERMISSIONS.md` for required permissions
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
