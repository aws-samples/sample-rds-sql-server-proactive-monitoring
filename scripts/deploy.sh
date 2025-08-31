#!/bin/bash

# SlackNotifier Lambda Deployment Script
# This script automates the deployment of the SlackNotifier Lambda function

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

# Configuration variables
AWS_REGION="${AWS_REGION:-us-east-1}"
FUNCTION_NAME="${FUNCTION_NAME:-SlackNotifier}"
ROLE_NAME="${ROLE_NAME:-SlackNotifierLambdaRole}"
POLICY_NAME="${POLICY_NAME:-SlackNotifierLambdaPolicy}"
LAYER_NAME="${LAYER_NAME:-urllib3-layer}"
TABLE_NAME="${TABLE_NAME:-SlackNotifierDDB}"

print_status "Starting SlackNotifier Lambda deployment..."
print_status "Region: $AWS_REGION"
print_status "Function Name: $FUNCTION_NAME"

# Get Slack Webhook URL from user
echo ""
print_status "Slack Webhook URL Configuration"
echo "You need to provide your Slack webhook URL for notifications."
echo "If you don't have one, create it at: https://api.slack.com/messaging/webhooks"
echo ""
read -p "Enter your Slack webhook URL: " -r SLACK_WEBHOOK_URL

if [ -z "$SLACK_WEBHOOK_URL" ]; then
    print_error "Slack webhook URL is required for deployment."
    exit 1
fi

# Validate webhook URL format
if [[ ! "$SLACK_WEBHOOK_URL" =~ ^https://hooks\.slack\.com/services/ ]]; then
    print_warning "Warning: The URL doesn't look like a standard Slack webhook URL."
    read -p "Continue anyway? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Deployment cancelled."
        exit 0
    fi
fi

print_success "The Slack webhook URL noted!"
echo ""

# Get AWS Account ID
print_status "Getting AWS Account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ "$?" -ne 0 ]; then
    print_error "Failed to get AWS Account ID. Please check your AWS CLI configuration."
    exit 1
fi
print_success "Fetched AWS Account ID"

# Check if required files exist
if [ ! -f "src/slacknotifier.py" ]; then
    print_error "src/slacknotifier.py not found. Please run this script from the project root directory."
    exit 1
fi

# Check if Python 3.12 is available
print_status "Checking Python 3.12 availability..."
if ! command -v python3.12 &> /dev/null; then
    print_error "Python 3.12 is not installed. Please install Python 3.12 first."
    print_error "You can install it using:"
    print_error "  - macOS: brew install python@3.12"
    print_error "  - Ubuntu/Debian: sudo apt install python3.12 python3.12-venv"
    print_error "  - CentOS/RHEL: sudo yum install python3.12"
    exit 1
fi

# Create and activate virtual environment
print_status "Creating Python 3.12 virtual environment..."
if [ -d "venv" ]; then
    print_warning "Virtual environment already exists, removing it..."
    rm -rf venv
fi

python3.12 -m venv venv
if [ "$?" -ne 0 ]; then
    print_error "Failed to create virtual environment with Python 3.12"
    exit 1
fi

# Activate virtual environment
print_status "Activating virtual environment..."
source venv/bin/activate

# Verify Python version in virtual environment
PYTHON_VERSION=$(python --version 2>&1)
print_success "Using Python version: $PYTHON_VERSION"

# Step 1: Create IAM Policy
print_status "Creating IAM policy..."
cat > lambda-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:DescribeTable",
        "dynamodb:Query",
        "dynamodb:PutItem",
        "dynamodb:UpdateTimeToLive",
        "dynamodb:Scan",
        "dynamodb:UpdateItem",
        "dynamodb:CreateTable"
      ],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
    }
  ]
}
EOF

# Check if policy already exists
if aws iam get-policy --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1; then
    print_warning "Policy $POLICY_NAME already exists, skipping creation"
else
    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document file://lambda-policy.json \
        --description "Policy for Lambda to access DynamoDB and CloudWatch Logs" >/dev/null
    print_success "IAM policy created: $POLICY_NAME"
fi
# Step 2: Create IAM Role
print_status "Creating IAM role..."
cat > trust-policy.json << EOF
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

# Check if role already exists
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    print_warning "Role $ROLE_NAME already exists, skipping creation"
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document file://trust-policy.json \
        --description "Execution role for SlackNotifier Lambda function" >/dev/null
    print_success "IAM role created: $ROLE_NAME"
    
    # Wait for role to be available
    sleep 10
fi

# Attach policies to role
print_status "Attaching policies to role..."
aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null 2>&1 || true

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}" >/dev/null 2>&1 || true

print_success "Policies attached to role"

# Step 3: Create Lambda Layer
print_status "Creating urllib3 layer..."

# Clean up any existing layer directory
rm -rf urllib3-layer

# Create layer directory structure
mkdir -p urllib3-layer/python
cd urllib3-layer

# Install urllib3 for Python 3.12 in virtual environment
print_status "Installing urllib3 in virtual environment..."
pip install urllib3 -t python/ >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
    print_error "Failed to install urllib3. Please ensure pip is available in the virtual environment."
    exit 1
fi

# Create ZIP file
zip -r urllib3-layer.zip python/ >/dev/null
print_success "Layer package created"

# Create the layer in AWS
print_status "Publishing layer to AWS..."
LAYER_VERSION_ARN=$(aws lambda publish-layer-version \
    --layer-name "$LAYER_NAME" \
    --description "Layer containing urllib3 library for Python 3.12" \
    --zip-file fileb://urllib3-layer.zip \
    --compatible-runtimes python3.12 \
    --query 'LayerVersionArn' \
    --output text)

if [ "$?" -eq 0 ]; then
    print_success "Layer published: $LAYER_VERSION_ARN"
else
    print_error "Failed to publish layer"
    exit 1
fi

# Go back to project directory
cd ..

# Step 4: Create DynamoDB Table
print_status "Creating DynamoDB table..."
if aws dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
    print_success "DynamoDB table already exists: $TABLE_NAME"
else
    print_status "Creating DynamoDB table: $TABLE_NAME"
    aws dynamodb create-table \
        --table-name "$TABLE_NAME" \
        --attribute-definitions \
            AttributeName=error_number,AttributeType=N \
            AttributeName=timestamp,AttributeType=N \
        --key-schema \
            AttributeName=error_number,KeyType=HASH \
            AttributeName=timestamp,KeyType=RANGE \
        --billing-mode PAY_PER_REQUEST >/dev/null
    
    print_status "Waiting for table to be active..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME"
    
    print_status "Enabling TTL on table..."
    aws dynamodb update-time-to-live \
        --table-name "$TABLE_NAME" \
        --time-to-live-specification Enabled=true,AttributeName=expiry_time >/dev/null
    
    print_success "DynamoDB table created and configured: $TABLE_NAME"
fi

# Step 5: Create Lambda Function
print_status "Creating Lambda function package..."
# Copy the source file to root level for proper Lambda packaging
cp src/slacknotifier.py slacknotifier.py
zip function.zip slacknotifier.py >/dev/null
rm slacknotifier.py

# Check if function already exists
if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
    print_warning "Function $FUNCTION_NAME already exists, updating code..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --zip-file fileb://function.zip >/dev/null
    print_success "Function code updated"
else
    print_status "Creating Lambda function..."
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --runtime python3.12 \
        --role "arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}" \
        --handler slacknotifier.lambda_handler \
        --zip-file fileb://function.zip \
        --description "Lambda function to send SQL Server error notifications to Slack" \
        --timeout 900 \
        --memory-size 128 >/dev/null
    
    if [ "$?" -eq 0 ]; then
        print_success "Lambda function created: $FUNCTION_NAME"
    else
        print_error "Failed to create Lambda function"
        exit 1
    fi
fi

# Wait for function to be active
print_status "Waiting for function to be active..."
aws lambda wait function-active --function-name "$FUNCTION_NAME"

# Step 6: Configure Environment Variables
print_status "Setting environment variables..."
aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "Variables={SLACK_WEBHOOK_URL=\"$SLACK_WEBHOOK_URL\",DYNAMODB_TABLE_NAME=\"$TABLE_NAME\",NOTIFICATION_COOLDOWN_MINUTES=\"15\",TTL_HOURS=\"10\"}" >/dev/null

print_success "Environment variables configured"

# Step 7: Attach Lambda Layer
print_status "Attaching layer to function..."
aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --layers "$LAYER_VERSION_ARN" >/dev/null

print_success "Layer attached to function"

# Step 8: Final verification
print_status "Verifying deployment..."
FUNCTION_ARN=$(aws lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --query 'FunctionArn' \
    --output text)

if [ "$?" -eq 0 ]; then
    print_success "Deployment completed successfully!"
    echo ""
    echo "=== Deployment Summary ==="
    echo "Function Name: $FUNCTION_NAME"
    echo "Function ARN: $FUNCTION_ARN"
    echo "Runtime: python3.12"
    echo "Region: $AWS_REGION"
    echo "Layer: $LAYER_NAME"
    echo ""
    print_success "Slack webhook URL configured: ${SLACK_WEBHOOK_URL:0:50}..."
    echo ""
    echo "If you need to update the Slack webhook URL later, run:"
    echo "aws lambda update-function-configuration \\"
    echo "    --function-name \"$FUNCTION_NAME\" \\"
    echo "    --environment \"Variables={SLACK_WEBHOOK_URL=\\\"$SLACK_WEBHOOK_URL\\\",DYNAMODB_TABLE_NAME=\\\"$TABLE_NAME\\\",NOTIFICATION_COOLDOWN_MINUTES=\\\"15\\\",TTL_HOURS=\\\"10\\\"}\""
else
    print_error "Deployment verification failed"
    exit 1
fi

# Cleanup temporary files
print_status "Cleaning up temporary files..."
rm -f lambda-policy.json trust-policy.json function.zip slacknotifier.py
rm -rf urllib3-layer/

# Remove virtual environment
if [ -d "venv" ]; then
    print_status "Removing virtual environment..."
        
    # Make all files writable before removal
    chmod -R u+w venv/ 2>/dev/null || true
    
    if rm -rf venv/ 2>/dev/null; then
        print_success "Virtual environment removed"
    else
        # If that fails, try more aggressive approach
        find venv -type d -exec chmod 755 {} \; 2>/dev/null || true
        find venv -type f -exec chmod 644 {} \; 2>/dev/null || true
        rm -rf venv/ 2>/dev/null || print_warning "Could not remove virtual environment, you may need to remove it manually"
    fi
fi

# Deactivate virtual environment
print_status "Deactivating virtual environment..."
deactivate

print_success "Temporary resources cleanup completed"
print_success "SlackNotifier Lambda deployment finished!"
