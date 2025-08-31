#!/bin/bash

# SlackNotifier Lambda Undeploy Script
# This script removes all AWS resources created by the deployment script

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration variables (same as deploy script)
AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-SlackNotifier}"
ROLE_NAME="${ROLE_NAME:-SlackNotifierLambdaRole}"
POLICY_NAME="${POLICY_NAME:-SlackNotifierLambdaPolicy}"
LAYER_NAME="${LAYER_NAME:-urllib3-layer}"
TABLE_NAME="${TABLE_NAME:-SlackNotifierDDB}"

print_status "Starting SlackNotifier Lambda undeploy process..."
print_status "Region: $AWS_REGION"
print_status "Function Name: $FUNCTION_NAME"

# Get AWS Account ID
print_status "Getting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ "$?" -ne 0 ]; then
    print_error "Failed to get AWS Account ID. Please check your AWS CLI configuration."
    exit 1
fi
print_success "Fetched AWS Account ID"

# Confirmation prompt
echo ""
print_warning "This will delete the following AWS resources:"
echo "  - Lambda Function: $FUNCTION_NAME"
echo "  - Lambda Layer: $LAYER_NAME (all versions)"
echo "  - IAM Role: $ROLE_NAME"
echo "  - IAM Policy: $POLICY_NAME"
echo "  - DynamoDB Table: $TABLE_NAME (if it exists)"
echo ""
print_warning "This action cannot be undone!"
echo ""
read -p "Are you sure you want to proceed? (yes/no): " -r
if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    print_status "Undeploy cancelled by user."
    exit 0
fi

echo ""
print_status "Proceeding with resource cleanup..."

# Step 1: Delete Lambda Function
print_status "Deleting Lambda function..."
if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
    aws lambda delete-function --function-name "$FUNCTION_NAME" >/dev/null
    print_success "Lambda function deleted: $FUNCTION_NAME"
else
    print_warning "Lambda function $FUNCTION_NAME not found, skipping"
fi

# Step 2: Delete Lambda Layer (all versions)
print_status "Deleting Lambda layer versions..."
LAYER_VERSIONS=$(aws lambda list-layer-versions --layer-name "$LAYER_NAME" --query 'LayerVersions[].Version' --output text 2>/dev/null || echo "")

if [ -n "$LAYER_VERSIONS" ]; then
    for version in $LAYER_VERSIONS; do
        print_status "Deleting layer version $version..."
        aws lambda delete-layer-version --layer-name "$LAYER_NAME" --version-number "$version" >/dev/null 2>&1 || true
    done
    print_success "All versions of layer $LAYER_NAME deleted"
else
    print_warning "No layer versions found for $LAYER_NAME, skipping"
fi

# Step 3: Detach policies from role and delete role
print_status "Cleaning up IAM role..."
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    # Detach AWS managed policy
    print_status "Detaching AWSLambdaBasicExecutionRole policy..."
    aws iam detach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true
    
    # Detach custom policy
    print_status "Detaching custom policy..."
    aws iam detach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1 || true
    
    # Delete role
    print_status "Deleting IAM role..."
    aws iam delete-role --role-name "$ROLE_NAME" >/dev/null
    print_success "IAM role deleted: $ROLE_NAME"
else
    print_warning "IAM role $ROLE_NAME not found, skipping"
fi

# Step 4: Delete IAM Policy
print_status "Deleting IAM policy..."
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1; then
    aws iam delete-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null
    print_success "IAM policy deleted: $POLICY_NAME"
else
    print_warning "IAM policy $POLICY_NAME not found, skipping"
fi

# Step 5: Delete DynamoDB Table (optional)
print_status "Checking for DynamoDB table..."
if aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
    echo ""
    print_warning "DynamoDB table '$TABLE_NAME' exists and contains your error tracking data."
    read -p "Do you want to delete the DynamoDB table? This will permanently delete all stored error data (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Deleting DynamoDB table..."
        aws dynamodb delete-table --table-name "$TABLE_NAME" >/dev/null
        print_success "DynamoDB table deleted: $TABLE_NAME"
        
        # Wait for table deletion to complete
        print_status "Waiting for table deletion to complete..."
        aws dynamodb wait table-not-exists --table-name "$TABLE_NAME"
        print_success "Table deletion completed"
    else
        print_warning "DynamoDB table $TABLE_NAME preserved"
    fi
else
    print_warning "DynamoDB table $TABLE_NAME not found, skipping"
fi

# Step 6: Clean up local files
print_status "Cleaning up local files..."
rm -f lambda-policy.json trust-policy.json function.zip test-event.json response.json
rm -rf urllib3-layer/

# Optional: Clean up virtual environment
if [ -d "venv" ]; then
    echo ""
    read -p "Do you want to remove the Python virtual environment? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Removing virtual environment..."
        
        # Make all files writable before removal
        chmod -R u+w venv/ 2>/dev/null || true
        
        # Try standard removal first
        if rm -rf venv/ 2>/dev/null; then
            print_success "Virtual environment removed"
        else
            # If that fails, try more aggressive approach
            print_status "Standard removal failed, trying alternative method..."
            find venv -type d -exec chmod 755 {} \; 2>/dev/null || true
            find venv -type f -exec chmod 644 {} \; 2>/dev/null || true
            
            if rm -rf venv/ 2>/dev/null; then
                print_success "Virtual environment removed"
            else
                print_error "Failed to remove virtual environment. You may need to remove it manually:"
                print_error "  sudo rm -rf venv/"
            fi
        fi
    else
        print_warning "Virtual environment preserved"
    fi
fi

print_success "Local cleanup completed"

echo ""
print_success "SlackNotifier Lambda undeploy completed successfully!"
echo ""
print_status "Summary of actions taken:"
echo "  ✓ Lambda function removed"
echo "  ✓ Lambda layer versions removed"
echo "  ✓ IAM role and policies removed"
if aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
    echo "  ⚠ DynamoDB table preserved (contains data)"
else
    echo "  ✓ DynamoDB table removed"
fi
echo "  ✓ Local temporary files cleaned up"

echo ""
print_status "If you need to redeploy, simply run: ./scripts/deploy.sh"