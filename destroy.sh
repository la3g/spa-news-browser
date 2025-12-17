#!/bin/bash

# ========================================
# AWS Lambda Destruction Script
# ========================================
# Usage: ./destroy.sh [profile-name] [region]
# Example: ./destroy.sh my-profile us-east-1

set -e

# Load environment variables from .env file if it exists
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Configuration
PROFILE="${AWS_PROFILE:-${1:-default}}"
REGION="${AWS_REGION:-${2:-us-east-1}}"
FUNCTION_NAME="spa-api-proxy"
ROLE_NAME="lambda-execution-role-spa"
CUSTOM_DOMAIN="browser.t.la3g.com"
PARENT_DOMAIN="t.la3g.com"
API_NAME="${FUNCTION_NAME}-api"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🗑️  Starting resource destruction...${NC}"
echo "Profile: $PROFILE"
echo "Region: $REGION"
echo "Function Name: $FUNCTION_NAME"
echo ""

# Confirmation
read -p "Are you sure you want to delete all resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo -e "${RED}❌ Destruction cancelled${NC}"
    exit 0
fi

# ========================================
# Step 1: Delete Function URL
# ========================================
echo ""
echo -e "${YELLOW}🔗 Step 1: Deleting Function URL...${NC}"

if aws lambda get-function-url-config --function-name $FUNCTION_NAME --profile $PROFILE --region $REGION &> /dev/null; then
    aws lambda delete-function-url-config \
        --function-name $FUNCTION_NAME \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
    
    echo -e "${GREEN}✓${NC} Function URL deleted"
else
    echo -e "${GREEN}✓${NC} Function URL does not exist"
fi

# ========================================
# Step 2: Delete Route 53 Records
# ========================================
echo ""
echo -e "${YELLOW}🌐 Step 2: Deleting Route 53 records...${NC}"

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$PARENT_DOMAIN" \
    --profile $PROFILE \
    --query "HostedZones[?Name=='${PARENT_DOMAIN}.'].Id" \
    --output text 2>/dev/null | sed 's|/hostedzone/||' | head -n1)

if [ ! -z "$HOSTED_ZONE_ID" ] && [ "$HOSTED_ZONE_ID" != "None" ]; then
    # Get existing record
    EXISTING_RECORD=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "$HOSTED_ZONE_ID" \
        --profile $PROFILE \
        --query "ResourceRecordSets[?Name=='${CUSTOM_DOMAIN}.']" \
        --output json 2>/dev/null)
    
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
                echo -e "${GREEN}✓${NC} CNAME record deleted"
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
                echo -e "${GREEN}✓${NC} ALIAS record deleted"
            fi
        fi
    else
        echo -e "${GREEN}✓${NC} Route 53 record does not exist"
    fi
    
    # Note: We don't delete the hosted zone itself as it might be used for other subdomains
    echo -e "${GREEN}✓${NC} Hosted zone preserved (may contain other records)"
else
    echo -e "${GREEN}✓${NC} Hosted zone does not exist"
fi

# ========================================
# Step 3: Delete API Gateway Custom Domain and Mappings
# ========================================
echo ""
echo -e "${YELLOW}🌐 Step 3: Deleting API Gateway custom domain...${NC}"

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

if [ ! -z "$MAPPINGS" ]; then
    echo -e "${GREEN}✓${NC} API mappings deleted"
fi

# Delete custom domain
if aws apigatewayv2 get-domain-name --domain-name "$CUSTOM_DOMAIN" --profile $PROFILE --region $REGION &> /dev/null; then
    aws apigatewayv2 delete-domain-name \
        --domain-name "$CUSTOM_DOMAIN" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
    
    echo -e "${GREEN}✓${NC} Custom domain deleted"
else
    echo -e "${GREEN}✓${NC} Custom domain does not exist"
fi

# ========================================
# Step 4: Delete API Gateway
# ========================================
echo ""
echo -e "${YELLOW}🌐 Step 4: Deleting API Gateway...${NC}"

EXISTING_API_ID=$(aws apigatewayv2 get-apis \
    --profile $PROFILE \
    --region $REGION \
    --query "Items[?Name=='${API_NAME}'].ApiId" \
    --output text 2>/dev/null | head -n1)

if [ ! -z "$EXISTING_API_ID" ] && [ "$EXISTING_API_ID" != "None" ]; then
    aws apigatewayv2 delete-api \
        --api-id "$EXISTING_API_ID" \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null 2>&1 || true
    
    echo -e "${GREEN}✓${NC} API Gateway deleted"
else
    echo -e "${GREEN}✓${NC} API Gateway does not exist"
fi

# ========================================
# Step 5: Delete Lambda Function
# ========================================
echo ""
echo -e "${YELLOW}⚡ Step 5: Deleting Lambda function...${NC}"

if aws lambda get-function --function-name $FUNCTION_NAME --profile $PROFILE --region $REGION &> /dev/null; then
    aws lambda delete-function \
        --function-name $FUNCTION_NAME \
        --profile $PROFILE \
        --region $REGION \
        --output json > /dev/null
    
    echo -e "${GREEN}✓${NC} Lambda function deleted"
else
    echo -e "${GREEN}✓${NC} Lambda function does not exist"
fi

# ========================================
# Step 6: Delete IAM Role
# ========================================
echo ""
echo -e "${YELLOW}🔐 Step 6: Deleting IAM Role...${NC}"

if aws iam get-role --role-name $ROLE_NAME --profile $PROFILE &> /dev/null; then
    # Detach policies first
    echo "Detaching policies..."
    
    # List attached policies
    POLICIES=$(aws iam list-attached-role-policies \
        --role-name $ROLE_NAME \
        --profile $PROFILE \
        --query 'AttachedPolicies[].PolicyArn' \
        --output text)
    
    for POLICY_ARN in $POLICIES; do
        if [ ! -z "$POLICY_ARN" ]; then
            aws iam detach-role-policy \
                --role-name $ROLE_NAME \
                --policy-arn "$POLICY_ARN" \
                --profile $PROFILE \
                --output json > /dev/null 2>&1 || true
        fi
    done
    
    # Delete inline policies
    INLINE_POLICIES=$(aws iam list-role-policies \
        --role-name $ROLE_NAME \
        --profile $PROFILE \
        --query 'PolicyNames' \
        --output text)
    
    for POLICY_NAME in $INLINE_POLICIES; do
        if [ ! -z "$POLICY_NAME" ]; then
            aws iam delete-role-policy \
                --role-name $ROLE_NAME \
                --policy-name "$POLICY_NAME" \
                --profile $PROFILE \
                --output json > /dev/null 2>&1 || true
        fi
    done
    
    # Delete the role
    aws iam delete-role \
        --role-name $ROLE_NAME \
        --profile $PROFILE \
        --output json > /dev/null
    
    echo -e "${GREEN}✓${NC} IAM Role deleted"
else
    echo -e "${GREEN}✓${NC} IAM Role does not exist"
fi

# ========================================
# Step 7: Cleanup local files
# ========================================
echo ""
echo -e "${YELLOW}🧹 Step 7: Cleaning up local files...${NC}"

if [ -f "function.zip" ]; then
    rm -f function.zip
    echo -e "${GREEN}✓${NC} Removed function.zip"
fi

# Cleanup temp files
rm -f /tmp/route53-delete.json
rm -f /tmp/route53-delete-alias.json

# ========================================
# Success Summary
# ========================================
echo ""
echo -e "${GREEN}✅ All resources destroyed successfully!${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🗑️  Destruction Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Function URL: Deleted"
echo "✓ Route 53 Records: Deleted"
echo "✓ API Gateway Custom Domain: Deleted"
echo "✓ API Gateway: Deleted"
echo "✓ Lambda Function: Deleted"
echo "✓ IAM Role: Deleted"
echo "✓ Local files: Cleaned"
echo ""
echo "Note: Route 53 hosted zone preserved (may contain other records)"
echo "Note: ACM certificates are not deleted (they expire automatically)"
echo ""
