#!/bin/bash

# ========================================
# AWS Lambda Deployment Script
# ========================================
# Usage: ./deploy.sh [profile-name] [region]
# Example: ./deploy.sh my-profile us-east-1

# Don't exit immediately on error - we want cleanup to run
set -o errexit
set -o pipefail

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Configuration
PROFILE="${AWS_PROFILE:-${1:-default}}"
REGION="${AWS_REGION:-${2:-us-east-1}}"
FUNCTION_NAME="spa-api-proxy"
ROLE_NAME="lambda-execution-role-spa"
POLICY_NAME="lambda-execution-policy-spa"
RESOURCE_TAG="browser.t.la3g.com"
CUSTOM_DOMAIN="browser.t.la3g.com"
PARENT_DOMAIN="t.la3g.com"
API_NAME="${FUNCTION_NAME}-api"

# Track created resources for rollback
CREATED_ROLE=false
CREATED_FUNCTION=false
CREATED_FUNCTION_URL=false
CREATED_API=false
CREATED_HOSTED_ZONE=false
CREATED_CNAME=false
CREATED_CERT=false
CREATED_CUSTOM_DOMAIN=false
DEPLOYMENT_FAILED=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ========================================
# Cleanup/Rollback Function
# ========================================
cleanup_on_error() {
    if [ "$DEPLOYMENT_FAILED" = true ]; then
        return  # Already cleaning up
    fi
    
    DEPLOYMENT_FAILED=true
    echo ""
    echo -e "${RED}❌ Deployment failed! Rolling back created resources...${NC}"
    echo ""
    
    # Delete in reverse order of creation
    
    # Delete Route 53 CNAME/ALIAS record
    if [ "$CREATED_CNAME" = true ] && [ ! -z "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
        echo -e "${YELLOW}Deleting Route 53 record...${NC}"
        EXISTING_RECORD=$(aws route53 list-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --profile $PROFILE \
            --query "ResourceRecordSets[?Name=='${CUSTOM_DOMAIN}.']" \
            --output json 2>/dev/null || echo "[]")
        
        if echo "$EXISTING_RECORD" | grep -q "CNAME\|A"; then
            RECORD_TYPE=$(echo "$EXISTING_RECORD" | grep -oP '"Type":\s*"\K[^"]+' | head -n1)
            if [ "$RECORD_TYPE" = "CNAME" ]; then
                RECORD_VALUE=$(echo "$EXISTING_RECORD" | grep -oP '"Value":\s*"\K[^"]+' | head -n1)
                if [ ! -z "$RECORD_VALUE" ]; then
                    cat > /tmp/route53-delete.json <<EOF
{
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": {
            "Name": "${CUSTOM_DOMAIN}.",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [{"Value": "${RECORD_VALUE}"}]
        }
    }]
}
EOF
                    aws route53 change-resource-record-sets \
                        --hosted-zone-id "$HOSTED_ZONE_ID" \
                        --change-batch file:///tmp/route53-delete.json \
                        --profile $PROFILE \
                        --output json > /dev/null 2>&1 || true
                    rm -f /tmp/route53-delete.json
                fi
            elif [ "$RECORD_TYPE" = "A" ]; then
                # Delete ALIAS record
                ALIAS_TARGET=$(echo "$EXISTING_RECORD" | grep -oP '"DNSName":\s*"\K[^"]+' | head -n1)
                ALIAS_ZONE=$(echo "$EXISTING_RECORD" | grep -oP '"HostedZoneId":\s*"\K[^"]+' | head -n1)
                if [ ! -z "$ALIAS_TARGET" ] && [ ! -z "$ALIAS_ZONE" ]; then
                    cat > /tmp/route53-delete-alias.json <<EOF
{
    "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": {
            "Name": "${CUSTOM_DOMAIN}.",
            "Type": "A",
            "AliasTarget": {
                "HostedZoneId": "${ALIAS_ZONE}",
                "DNSName": "${ALIAS_TARGET}",
                "EvaluateTargetHealth": false
            }
        }
    }]
}
EOF
                    aws route53 change-resource-record-sets \
                        --hosted-zone-id "$HOSTED_ZONE_ID" \
                        --change-batch file:///tmp/route53-delete-alias.json \
                        --profile $PROFILE \
                        --output json > /dev/null 2>&1 || true
                    rm -f /tmp/route53-delete-alias.json
                fi
            fi
        fi
    fi
    
    # Delete API Gateway custom domain
    if [ "$CREATED_CUSTOM_DOMAIN" = true ]; then
        echo -e "${YELLOW}Deleting API Gateway custom domain...${NC}"
        # Delete API mappings first
        MAPPINGS=$(aws apigatewayv2 get-api-mappings \
            --domain-name "$CUSTOM_DOMAIN" \
            --profile $PROFILE \
            --region $REGION \
            --query "Items[].ApiMappingId" \
            --output text 2>/dev/null || echo "")
        
        for MAPPING_ID in $MAPPINGS; do
            if [ ! -z "$MAPPING_ID" ]; then
                aws apigatewayv2 delete-api-mapping \
                    --domain-name "$CUSTOM_DOMAIN" \
                    --api-mapping-id "$MAPPING_ID" \
                    --profile $PROFILE \
                    --region $REGION \
                    --output json > /dev/null 2>&1 || true
            fi
        done
        
        aws apigatewayv2 delete-domain-name \
            --domain-name "$CUSTOM_DOMAIN" \
            --profile $PROFILE \
            --region $REGION \
            --output json > /dev/null 2>&1 || true
    fi
    
    # Delete API Gateway
    if [ "$CREATED_API" = true ] && [ ! -z "$API_ID" ]; then
        echo -e "${YELLOW}Deleting API Gateway...${NC}"
        aws apigatewayv2 delete-api \
            --api-id "$API_ID" \
            --profile $PROFILE \
            --region $REGION \
            --output json > /dev/null 2>&1 || true
    fi
    
    # Delete Function URL
    if [ "$CREATED_FUNCTION_URL" = true ]; then
        echo -e "${YELLOW}Deleting Function URL...${NC}"
        aws lambda delete-function-url-config \
            --function-name $FUNCTION_NAME \
            --profile $PROFILE \
            --region $REGION \
            --output json > /dev/null 2>&1 || true
    fi
    
    # Delete Lambda Function
    if [ "$CREATED_FUNCTION" = true ]; then
        echo -e "${YELLOW}Deleting Lambda function...${NC}"
        aws lambda delete-function \
            --function-name $FUNCTION_NAME \
            --profile $PROFILE \
            --region $REGION \
            --output json > /dev/null 2>&1 || true
    fi
    
    # Delete IAM Role (only if we created it)
    if [ "$CREATED_ROLE" = true ]; then
        echo -e "${YELLOW}Deleting IAM Role...${NC}"
        # Detach policies first
        aws iam detach-role-policy \
            --role-name $ROLE_NAME \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
            --profile $PROFILE \
            --output json > /dev/null 2>&1 || true
        
        aws iam delete-role \
            --role-name $ROLE_NAME \
            --profile $PROFILE \
            --output json > /dev/null 2>&1 || true
    fi
    
    # Cleanup temp files
    rm -f /tmp/trust-policy.json
    rm -f /tmp/route53-change.json
    rm -f /tmp/route53-alias.json
    rm -f /tmp/route53-delete.json
    rm -f /tmp/route53-delete-alias.json
    rm -f /tmp/acm-validation.json
    rm -f function.zip
    
    echo ""
    echo -e "${RED}❌ Rollback complete${NC}"
    exit 1
}

# Set trap to call cleanup on error
trap cleanup_on_error ERR
trap cleanup_on_error INT TERM

echo -e "${GREEN}🚀 Starting deployment...${NC}"
echo "Profile: $PROFILE"
echo "Region: $REGION"
echo "Function Name: $FUNCTION_NAME"
echo "Resource Tag: $RESOURCE_TAG"
echo "Custom Domain: $CUSTOM_DOMAIN"
echo ""

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}❌ AWS CLI is not installed${NC}"
    exit 1
fi

# Check if profile exists
if ! aws configure list-profiles --profile $PROFILE &> /dev/null; then
    echo -e "${RED}❌ AWS profile '$PROFILE' not found${NC}"
    exit 1
fi

# Get account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile $PROFILE --query Account --output text)
echo -e "${GREEN}✓${NC} Account ID: $ACCOUNT_ID"

# ========================================
# Step 1: Create IAM Role (if it doesn't exist)
# ========================================
echo ""
echo -e "${YELLOW}📋 Step 1: Checking IAM Role...${NC}"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

if aws iam get-role --role-name $ROLE_NAME --profile $PROFILE &> /dev/null; then
    echo -e "${GREEN}✓${NC} IAM Role already exists: $ROLE_NAME"
    
    # Tag existing role
    aws iam tag-role \
        --role-name $ROLE_NAME \
        --tags "Key=Project,Value=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --output json > /dev/null 2>&1 || true
else
    echo "Creating IAM Role..."
    
    # Create trust policy
    cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
    
    aws iam create-role \
        --role-name $ROLE_NAME \
        --assume-role-policy-document file:///tmp/trust-policy.json \
        --profile $PROFILE \
        --description "Execution role for SPA API Proxy Lambda function" \
        --tags "Key=Project,Value=${RESOURCE_TAG}"
    
    CREATED_ROLE=true
    echo -e "${GREEN}✓${NC} IAM Role created"
    
    # Attach basic Lambda execution policy
    aws iam attach-role-policy \
        --role-name $ROLE_NAME \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
        --profile $PROFILE
    
    echo -e "${GREEN}✓${NC} Basic execution policy attached"
fi

# ========================================
# Step 2: Prepare Lambda Package
# ========================================
echo ""
echo -e "${YELLOW}📦 Step 2: Preparing Lambda package...${NC}"

cd lambda-function

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo "Installing npm dependencies..."
    npm install --production
fi

# Create deployment package
echo "Creating deployment package..."
zip -r ../function.zip . -x "*.git*" "*.DS_Store*" "deploy.sh" "destroy.sh" > /dev/null

cd ..

echo -e "${GREEN}✓${NC} Package created: function.zip ($(du -h function.zip | cut -f1))"

# ========================================
# Step 3: Create or Update Lambda Function
# ========================================
echo ""
echo -e "${YELLOW}⚡ Step 3: Deploying Lambda function...${NC}"

# Check if function exists
if aws lambda get-function --function-name $FUNCTION_NAME --profile $PROFILE --region $REGION &> /dev/null; then
    echo "Function exists, updating..."
    
    aws lambda update-function-code \
        --function-name $FUNCTION_NAME \
        --zip-file fileb://function.zip \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    echo -e "${GREEN}✓${NC} Function code updated"
    
    # Update environment variables
    aws lambda update-function-configuration \
        --function-name $FUNCTION_NAME \
        --environment Variables="{
            GEMINI_API_KEY=${GEMINI_API_KEY},
            SUPABASE_URL=${SUPABASE_URL},
            SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
        }" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    echo -e "${GREEN}✓${NC} Environment variables updated"
    
    # Tag function
    aws lambda tag-resource \
        --resource "arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}" \
        --tags "Project=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
else
    echo "Creating new function..."
    
    aws lambda create-function \
        --function-name $FUNCTION_NAME \
        --runtime nodejs20.x \
        --role $ROLE_ARN \
        --handler index.handler \
        --zip-file fileb://function.zip \
        --timeout 30 \
        --memory-size 256 \
        --environment Variables="{
            GEMINI_API_KEY=${GEMINI_API_KEY},
            SUPABASE_URL=${SUPABASE_URL},
            SUPABASE_ANON_KEY=${SUPABASE_ANON_KEY}
        }" \
        --tags "Project=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    CREATED_FUNCTION=true
    echo -e "${GREEN}✓${NC} Function created"
fi

# ========================================
# Step 4: Create Function URL
# ========================================
echo ""
echo -e "${YELLOW}🔗 Step 4: Configuring Function URL...${NC}"

# Check if Function URL exists
FUNCTION_URL_CONFIG=$(aws lambda get-function-url-config \
    --function-name $FUNCTION_NAME \
    --profile $PROFILE \
    --region $REGION \
    --output json 2>/dev/null || echo "{}")

if echo "$FUNCTION_URL_CONFIG" | grep -q "FunctionUrl"; then
    echo -e "${GREEN}✓${NC} Function URL already exists"
    FUNCTION_URL=$(echo "$FUNCTION_URL_CONFIG" | grep -oP '"FunctionUrl":\s*"\K[^"]+')
else
    echo "Creating Function URL..."
    
    FUNCTION_URL_OUTPUT=$(aws lambda create-function-url-config \
        --function-name $FUNCTION_NAME \
        --auth-type NONE \
        --cors '{
            "AllowOrigins": ["*"],
            "AllowMethods": ["POST", "OPTIONS"],
            "AllowHeaders": ["Content-Type"],
            "MaxAge": 3600
        }' \
        --profile $PROFILE \
        --region $REGION \
        --output json)
    
    FUNCTION_URL=$(echo "$FUNCTION_URL_OUTPUT" | grep -oP '"FunctionUrl":\s*"\K[^"]+')
    CREATED_FUNCTION_URL=true
    echo -e "${GREEN}✓${NC} Function URL created"
fi

# ========================================
# Step 5: Add Function URL Permission
# ========================================
echo ""
echo -e "${YELLOW}🔐 Step 5: Setting Function URL permissions...${NC}"

# Check if permission exists
STATEMENT_ID="FunctionURLAllowPublicAccess"
if aws lambda get-policy \
    --function-name $FUNCTION_NAME \
    --profile $PROFILE \
    --region $REGION \
    --output json 2>/dev/null | grep -q "$STATEMENT_ID"; then
    echo -e "${GREEN}✓${NC} Permission already exists"
else
    aws lambda add-permission \
        --function-name $FUNCTION_NAME \
        --statement-id $STATEMENT_ID \
        --action lambda:InvokeFunctionUrl \
        --principal "*" \
        --function-url-auth-type NONE \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    echo -e "${GREEN}✓${NC} Public access permission added"
fi

# ========================================
# Step 6: Setup API Gateway and Route 53
# ========================================
echo ""
echo -e "${YELLOW}🌐 Step 6: Setting up API Gateway and Route 53...${NC}"

# Get Lambda function ARN
FUNCTION_ARN=$(aws lambda get-function \
    --function-name $FUNCTION_NAME \
    --profile $PROFILE \
    --region $REGION \
    --query "Configuration.FunctionArn" \
    --output text)

# ========================================
# Step 6a: Create or Get Route 53 Hosted Zone
# ========================================
echo "Checking Route 53 hosted zone for $PARENT_DOMAIN..."

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$PARENT_DOMAIN" \
    --profile $PROFILE \
    --query "HostedZones[?Name=='${PARENT_DOMAIN}.'].Id" \
    --output text 2>/dev/null | sed 's|/hostedzone/||' | head -n1)

if [ -z "$HOSTED_ZONE_ID" ] || [ "$HOSTED_ZONE_ID" = "None" ]; then
    echo "Creating Route 53 hosted zone for $PARENT_DOMAIN..."
    
    HOSTED_ZONE_OUTPUT=$(aws route53 create-hosted-zone \
        --name "$PARENT_DOMAIN" \
        --caller-reference "spa-api-$(date +%s)" \
        --hosted-zone-config "Comment=SPA API Proxy for ${RESOURCE_TAG}" \
        --profile $PROFILE \
        --output json)
    
    HOSTED_ZONE_ID=$(echo "$HOSTED_ZONE_OUTPUT" | grep -oP '"Id":\s*"/hostedzone/\K[^"]+')
    CREATED_HOSTED_ZONE=true
    
    # Tag hosted zone
    aws route53 change-tags-for-resource \
        --resource-type hostedzone \
        --resource-id "$HOSTED_ZONE_ID" \
        --add-tags "Key=Project,Value=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --output json > /dev/null 2>&1 || true
    
    # Get name servers
    NAME_SERVERS=$(aws route53 get-hosted-zone \
        --id "$HOSTED_ZONE_ID" \
        --profile $PROFILE \
        --query "DelegationSet.NameServers" \
        --output text)
    
    echo -e "${GREEN}✓${NC} Hosted zone created: $HOSTED_ZONE_ID"
    echo ""
    echo -e "${YELLOW}⚠️  IMPORTANT: Delegate subdomain in Namecheap DNS:${NC}"
    echo "   Create NS records for 't' pointing to:"
    for ns in $NAME_SERVERS; do
        echo "     - $ns"
    done
    echo ""
else
    echo -e "${GREEN}✓${NC} Hosted zone already exists: $HOSTED_ZONE_ID"
    
    # Tag existing hosted zone
    aws route53 change-tags-for-resource \
        --resource-type hostedzone \
        --resource-id "$HOSTED_ZONE_ID" \
        --add-tags "Key=Project,Value=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --output json > /dev/null 2>&1 || true
fi

# ========================================
# Step 6b: Create or Get API Gateway HTTP API
# ========================================
echo "Checking API Gateway..."

EXISTING_API_ID=$(aws apigatewayv2 get-apis \
    --profile $PROFILE \
    --region $REGION \
    --query "Items[?Name=='${API_NAME}'].ApiId" \
    --output text 2>/dev/null | head -n1)

if [ -z "$EXISTING_API_ID" ] || [ "$EXISTING_API_ID" = "None" ]; then
    echo "Creating HTTP API Gateway..."
    
    # Create API
    API_OUTPUT=$(aws apigatewayv2 create-api \
        --name "$API_NAME" \
        --protocol-type HTTP \
        --cors-configuration '{
            "AllowOrigins": ["*"],
            "AllowMethods": ["POST", "OPTIONS"],
            "AllowHeaders": ["Content-Type"],
            "MaxAge": 3600
        }' \
        --tags "Project=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --region $REGION \
        --output json)
    
    API_ID=$(echo "$API_OUTPUT" | grep -oP '"ApiId":\s*"\K[^"]+')
    CREATED_API=true
    
    # Create integration with Lambda
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type AWS_PROXY \
        --integration-uri "$FUNCTION_ARN" \
        --integration-method POST \
        --payload-format-version "2.0" \
        --profile $PROFILE \
        --region $REGION \
        --query "IntegrationId" \
        --output text)
    
    # Create route (catch-all)
    aws apigatewayv2 create-route \
        --api-id "$API_ID" \
        --route-key "\$default" \
        --target "integrations/$INTEGRATION_ID" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    # Deploy to stage
    aws apigatewayv2 create-stage \
        --api-id "$API_ID" \
        --stage-name "\$default" \
        --auto-deploy \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    # Add Lambda permission for API Gateway
    aws lambda add-permission \
        --function-name $FUNCTION_NAME \
        --statement-id "apigateway-invoke-${API_ID}" \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
    
    echo -e "${GREEN}✓${NC} API Gateway created: $API_ID"
else
    API_ID="$EXISTING_API_ID"
    echo -e "${GREEN}✓${NC} API Gateway already exists: $API_ID"
    
    # Tag existing API Gateway
    aws apigatewayv2 tag-resource \
        --resource-arn "arn:aws:apigateway:${REGION}::/apis/${API_ID}" \
        --tags "Project=${RESOURCE_TAG}" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
fi

# Get API endpoint
API_ENDPOINT=$(aws apigatewayv2 get-api \
    --api-id "$API_ID" \
    --profile $PROFILE \
    --region $REGION \
    --query "ApiEndpoint" \
    --output text)

# Extract domain from API endpoint (e.g., abc123.execute-api.us-east-1.amazonaws.com)
API_DOMAIN=$(echo "$API_ENDPOINT" | sed 's|https\?://||')

# ========================================
# Step 6c: Request ACM Certificate (if needed)
# ========================================
echo "Checking ACM certificate for $CUSTOM_DOMAIN..."

CERT_ARN=$(aws acm list-certificates \
    --region us-east-1 \
    --profile $PROFILE \
    --query "CertificateSummaryList[?DomainName=='${CUSTOM_DOMAIN}'].CertificateArn" \
    --output text 2>/dev/null | head -n1)

if [ -z "$CERT_ARN" ] || [ "$CERT_ARN" = "None" ]; then
    echo "Requesting ACM certificate for $CUSTOM_DOMAIN..."
    
    CERT_OUTPUT=$(aws acm request-certificate \
        --domain-name "$CUSTOM_DOMAIN" \
        --validation-method DNS \
        --region us-east-1 \
        --profile $PROFILE \
        --tags "Key=Project,Value=${RESOURCE_TAG}" \
        --output json)
    
    CERT_ARN=$(echo "$CERT_OUTPUT" | grep -oP '"CertificateArn":\s*"\K[^"]+')
    CREATED_CERT=true
    
    echo -e "${GREEN}✓${NC} Certificate requested: $CERT_ARN"
    echo ""
    echo -e "${YELLOW}⚠️  Certificate validation required. Waiting 10 seconds for DNS records...${NC}"
    sleep 10
    
    # Get validation records
    CERT_DETAILS=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region us-east-1 \
        --profile $PROFILE \
        --output json)
    
    VALIDATION_RECORDS=$(echo "$CERT_DETAILS" | grep -oP '"ResourceRecord":\s*\{[^}]+\}' | head -n1)
    
    if [ ! -z "$VALIDATION_RECORDS" ]; then
        VALIDATION_NAME=$(echo "$CERT_DETAILS" | grep -oP '"Name":\s*"\K[^"]+' | head -n1)
        VALIDATION_VALUE=$(echo "$CERT_DETAILS" | grep -oP '"Value":\s*"\K[^"]+' | head -n1)
        
        echo "Adding certificate validation record to Route 53..."
        
        cat > /tmp/acm-validation.json <<EOF
{
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": "${VALIDATION_NAME}",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [{"Value": "${VALIDATION_VALUE}"}]
        }
    }]
}
EOF
        
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch file:///tmp/acm-validation.json \
            --profile $PROFILE \
            --output json > /dev/null
        
        rm -f /tmp/acm-validation.json
        
        echo -e "${GREEN}✓${NC} Validation record added. Certificate validation in progress..."
        echo "   This may take 5-30 minutes. The custom domain will work once validated."
    fi
else
    # Check if certificate is validated
    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region us-east-1 \
        --profile $PROFILE \
        --query "Certificate.Status" \
        --output text)
    
    if [ "$CERT_STATUS" != "ISSUED" ]; then
        echo -e "${YELLOW}⚠️  Certificate exists but not validated (Status: $CERT_STATUS)${NC}"
        echo "   Custom domain will not work until certificate is validated."
    else
        echo -e "${GREEN}✓${NC} Certificate validated: $CERT_ARN"
    fi
fi

# ========================================
# Step 6d: Create API Gateway Custom Domain
# ========================================
if [ ! -z "$CERT_ARN" ] && [ "$CERT_ARN" != "None" ]; then
    echo "Creating API Gateway custom domain..."
    
    # Check if custom domain exists
    EXISTING_DOMAIN=$(aws apigatewayv2 get-domain-names \
        --profile $PROFILE \
        --region $REGION \
        --query "Items[?DomainName=='${CUSTOM_DOMAIN}'].DomainName" \
        --output text 2>/dev/null | head -n1)
    
    if [ -z "$EXISTING_DOMAIN" ] || [ "$EXISTING_DOMAIN" = "None" ]; then
        DOMAIN_OUTPUT=$(aws apigatewayv2 create-domain-name \
            --domain-name "$CUSTOM_DOMAIN" \
            --domain-name-configurations "CertificateArn=${CERT_ARN}" \
            --tags "Project=${RESOURCE_TAG}" \
            --profile $PROFILE \
            --region $REGION \
            --output json)
        
        CREATED_CUSTOM_DOMAIN=true
        echo -e "${GREEN}✓${NC} Custom domain created"
    else
        echo -e "${GREEN}✓${NC} Custom domain already exists"
    fi
    
    # Get custom domain target
    CUSTOM_DOMAIN_TARGET=$(aws apigatewayv2 get-domain-name \
        --domain-name "$CUSTOM_DOMAIN" \
        --profile $PROFILE \
        --region $REGION \
        --query "DomainNameConfigurations[0].TargetDomainName" \
        --output text 2>/dev/null)
    
    # Create API mapping
    EXISTING_MAPPING=$(aws apigatewayv2 get-api-mappings \
        --domain-name "$CUSTOM_DOMAIN" \
        --profile $PROFILE \
        --region $REGION \
        --query "Items[?ApiId=='${API_ID}'].ApiMappingId" \
        --output text 2>/dev/null | head -n1)
    
    if [ -z "$EXISTING_MAPPING" ] || [ "$EXISTING_MAPPING" = "None" ]; then
        aws apigatewayv2 create-api-mapping \
            --domain-name "$CUSTOM_DOMAIN" \
            --api-id "$API_ID" \
            --stage "\$default" \
            --profile $PROFILE \
            --region $REGION \
            --output json > /dev/null
        
        echo -e "${GREEN}✓${NC} API mapping created"
    else
        echo -e "${GREEN}✓${NC} API mapping already exists"
    fi
    
    # Update Route 53 to use ALIAS record pointing to custom domain
    if [ ! -z "$CUSTOM_DOMAIN_TARGET" ]; then
        echo "Updating Route 53 record to use custom domain..."
        
        # Get the hosted zone ID for the custom domain target (CloudFront distribution)
        # API Gateway custom domains use CloudFront, which has a specific zone ID
        CUSTOM_DOMAIN_ZONE_ID="Z2FDTNDATAQYW2"  # CloudFront hosted zone ID (constant)
        
        # Delete old CNAME if exists, create ALIAS
        cat > /tmp/route53-alias.json <<EOF
{
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": "${CUSTOM_DOMAIN}.",
            "Type": "A",
            "AliasTarget": {
                "HostedZoneId": "${CUSTOM_DOMAIN_ZONE_ID}",
                "DNSName": "${CUSTOM_DOMAIN_TARGET}.",
                "EvaluateTargetHealth": false
            }
        }
    }]
}
EOF
        
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch file:///tmp/route53-alias.json \
            --profile $PROFILE \
            --output json > /dev/null
        
        CREATED_CNAME=true
        rm -f /tmp/route53-alias.json
        echo -e "${GREEN}✓${NC} Route 53 ALIAS record created"
    fi
else
    # Fallback: Create CNAME to API Gateway endpoint (without custom domain)
    echo "Creating CNAME record: $CUSTOM_DOMAIN -> $API_DOMAIN"
    
    EXISTING_RECORD=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --profile $PROFILE \
        --query "ResourceRecordSets[?Name=='${CUSTOM_DOMAIN}.']" \
        --output json 2>/dev/null)
    
    if echo "$EXISTING_RECORD" | grep -q "CNAME"; then
        echo -e "${GREEN}✓${NC} CNAME record already exists"
    else
        cat > /tmp/route53-change.json <<EOF
{
    "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
            "Name": "${CUSTOM_DOMAIN}.",
            "Type": "CNAME",
            "TTL": 300,
            "ResourceRecords": [{"Value": "${API_DOMAIN}"}]
        }
    }]
}
EOF
        
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch file:///tmp/route53-change.json \
            --profile $PROFILE \
            --output json > /dev/null
        
        CREATED_CNAME=true
        echo -e "${GREEN}✓${NC} CNAME record created"
        rm -f /tmp/route53-change.json
    fi
fi

CUSTOM_DOMAIN_URL="https://${CUSTOM_DOMAIN}"

# ========================================
# Cleanup temp files
# ========================================
rm -f /tmp/trust-policy.json

# Disable error trap - deployment succeeded
trap - ERR INT TERM

# ========================================
# Success Summary
# ========================================
echo ""
echo -e "${GREEN}✅ Deployment completed successfully!${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Deployment Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Function Name: $FUNCTION_NAME"
echo "Region: $REGION"
echo "Role ARN: $ROLE_ARN"
echo "Resource Tag: $RESOURCE_TAG"
echo ""
echo -e "${GREEN}🔗 Function URL:${NC}"
echo "$FUNCTION_URL"
echo ""
echo -e "${GREEN}🌐 Custom Domain:${NC}"
echo "$CUSTOM_DOMAIN_URL"
echo ""

if [ "$CREATED_CERT" = true ]; then
    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region us-east-1 \
        --profile $PROFILE \
        --query "Certificate.Status" \
        --output text)
    
    if [ "$CERT_STATUS" != "ISSUED" ]; then
        echo -e "${YELLOW}⚠️  Certificate Status: $CERT_STATUS${NC}"
        echo "   The custom domain will work once the certificate is validated (5-30 minutes)."
        echo "   Check status with:"
        echo "   aws acm describe-certificate --certificate-arn $CERT_ARN --region us-east-1 --profile $PROFILE"
        echo ""
    fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "⚠️  IMPORTANT: Update your SPA with this URL:"
echo "   const LAMBDA_FUNCTION_URL = '$CUSTOM_DOMAIN_URL';"
echo ""
echo "To destroy resources, run: ./destroy.sh $PROFILE $REGION"
echo ""
