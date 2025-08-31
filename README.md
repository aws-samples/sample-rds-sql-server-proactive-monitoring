# Proactive monitoring for Amazon RDS for SQL Server with real-time Slack notifications

A comprehensive serverless solution for monitoring Amazon RDS for SQL Server with real-time Slack notifications for proactive error detection and alerting.

## Overview

This project implements a serverless monitoring solution that:
- Processes Amazon RDS for SQL Server error logs via CloudWatch
- Parses SQL Server error messages using intelligent pattern matching
- Stores error state in DynamoDB to prevent duplicate notifications
- Sends formatted alerts to Slack channels for immediate team notification
- Handles multi-line error messages and implements notification cooldowns

## Architecture

The solution uses AWS Lambda to process CloudWatch log events, parse SQL Server errors, store state in DynamoDB, and send notifications to Slack webhooks.

## Project Structure

```
rds-monitoring-blog/
├── src/                     # Lambda function source code
│   └── slacknotifier.py    # Main Lambda function
├── scripts/                 # Deployment automation scripts
│   ├── deploy.sh           # Automated deployment script
│   └── undeploy.sh         # Automated cleanup script
└── README.md               # Project documentation and setup guide
```

## Features

### Lambda Function (`src/slacknotifier.py`)

The core Lambda function provides:

1. **CloudWatch Log Processing**: Decodes base64-encoded and gzipped log data from CloudWatch
2. **SQL Server Error Parsing**: Extracts error details using regex patterns for different SQL Server error formats
3. **State Management**: Uses pre-existing DynamoDB table to track errors and prevent duplicate notifications
4. **Slack Integration**: Posts formatted error messages to Slack via webhook
5. **Multi-line Error Handling**: Manages SQL Server error messages that span multiple log entries
6. **Message Filtering**: Ignores informational messages and focuses on actual errors

#### Key Functions:
- `decode_cloudwatch_log()` - Decodes and decompresses CloudWatch log data
- `parse_sql_error()` - Extracts error information from SQL Server log messages
- `post_to_slack()` - Sends formatted messages to Slack
- `get_dynamodb_table()` - Gets reference to the pre-existing DynamoDB table
- `store_in_dynamodb()` - Stores error data with TTL for tracking
- `should_send_slack_notification()` - Determines if notification should be sent based on cooldown
- `should_ignore_message()` - Filters out informational messages
- `lambda_handler()` - Main entry point for the Lambda function

#### Environment Variables:
- `SLACK_WEBHOOK_URL` - Slack webhook URL for notifications
- `DYNAMODB_TABLE_NAME` - DynamoDB table name for error tracking (default: SlackNotifierDDB)
- `NOTIFICATION_COOLDOWN_MINUTES` - Cooldown period between duplicate notifications (default: 15)
- `TTL_HOURS` - Time-to-live for DynamoDB entries (default: 10)

### Deployment Scripts

#### `scripts/deploy.sh`
Automated deployment script with features:
- ✅ Prompts for and validates Slack webhook URL during deployment
- ✅ Creates DynamoDB table with proper schema and TTL configuration before Lambda deployment
- ✅ Creates IAM policies and roles with proper permissions
- ✅ Builds and publishes urllib3 Lambda layer for Python 3.12
- ✅ Packages and deploys the Lambda function with correct handler configuration
- ✅ Configures environment variables including Slack webhook URL automatically
- ✅ Attaches the urllib3 layer to the function
- ✅ Provides colored output and comprehensive error handling
- ✅ Checks for existing resources to avoid conflicts
- ✅ Automatically cleans up temporary files and virtual environment
- ✅ Copies source file to root level for proper Lambda packaging

#### `scripts/undeploy.sh`
Automated cleanup script with features:
- ✅ Safely removes all AWS resources created during deployment
- ✅ Prompts for confirmation before deleting resources
- ✅ Handles DynamoDB table deletion separately (preserves data by default)
- ✅ Robust virtual environment removal with permission handling
- ✅ Cleans up local files and temporary directories
- ✅ Provides detailed summary of actions taken
- ✅ Colored output and error handling



## Quick Start

### Prerequisites

- AWS CLI installed and configured with appropriate permissions
- Python 3.12 installed locally (the script will create an isolated virtual environment)
- zip utility available
- Proper AWS permissions (see detailed requirements below)

#### Installing Python 3.12

If Python 3.12 is not installed on your system:

**macOS:**
```bash
# Using Homebrew
brew install python@3.12
```

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install python3.12 python3.12-venv python3.12-pip
```

**CentOS/RHEL/Amazon Linux:**
```bash
sudo yum install python3.12 python3.12-pip
# or for newer versions
sudo dnf install python3.12 python3.12-pip
```

**Windows:**
Download and install from [python.org](https://www.python.org/downloads/) or use Windows Package Manager:
```bash
winget install Python.Python.3.12
```

#### Required AWS Permissions

Your AWS user/role must have the following AWS managed policies attached to deploy this solution:

**Recommended Approach (Simplest):**
- `PowerUserAccess` - Provides full access to AWS services except IAM user/group management (recommended for development/testing)

**Alternative Approach (More Restrictive):**
If you prefer more granular permissions, attach these AWS managed policies:
- `IAMFullAccess` - For creating IAM roles and policies
- `AWSLambda_FullAccess` - For creating and managing Lambda functions and layers
- `AmazonDynamoDBFullAccess` - For creating and managing DynamoDB tables

**Permission Verification:**
```bash
# Test basic AWS access
aws sts get-caller-identity

# Test IAM permissions
aws iam list-policies --max-items 1

# Test Lambda permissions
aws lambda list-functions --max-items 1
```

**Security Note:** The deployment script creates resources that will have DynamoDB permissions. The Lambda function itself will be granted permissions to create and manage a DynamoDB table named `SlackNotifierDDB` for error tracking.

### Create Slack Webhook URL

Before deploying, you need to create a Slack webhook URL:

1. **Open your Slack workspace**
2. **Navigate to the workspace settings**
3. **Choose Apps & Integrations**
4. **Search for "incoming webhooks"**
5. **Choose "Add to Slack"**
6. **Choose the channel for notifications**
7. **Copy the webhook URL** - you'll need this during deployment

### Automated Deployment

1. **Create Slack Webhook URL** (see instructions above)
2. **Clone the repository**
3. **Navigate to the project root directory**
4. **Run the automated deployment script:**
   ```bash
   ./scripts/deploy.sh
   ```
   
5. **When prompted, enter your Slack webhook URL**

   The script will automatically:
   - Prompt for and validate your Slack webhook URL
   - Verify Python 3.12 is installed on your system
   - Create an isolated Python 3.12 virtual environment (`venv/`)
   - Activate the virtual environment for dependency isolation
   - Install urllib3 in the isolated environment
   - Create DynamoDB table (`SlackNotifierDDB`) with proper schema and TTL
   - Create IAM policy (`SlackNotifierLambdaPolicy`) with DynamoDB permissions
   - Create IAM role (`SlackNotifierLambdaRole`) with proper trust relationships
   - Build and publish urllib3 Lambda layer using Python 3.12
   - Package and deploy the Lambda function (`SlackNotifier`) with correct handler configuration
   - Configure environment variables including your Slack webhook URL automatically
   - Attach the urllib3 layer to the function
   - Clean up temporary files and virtual environment automatically

**That's it!** Your monitoring solution is fully configured and ready to use.

**Note:** The script automatically cleans up the virtual environment and temporary files after deployment, keeping your workspace clean.

### Customization

You can customize the deployment by setting environment variables:

```bash
export AWS_REGION="us-east-1"           # Default: us-east-1
export FUNCTION_NAME="SlackNotifier"  # Default: SlackNotifier
export ROLE_NAME="SlackNotifierLambdaRole"         # Default: SlackNotifierLambdaRole
export POLICY_NAME="SlackNotifierLambdaPolicy"     # Default: SlackNotifierLambdaPolicy
export LAYER_NAME="urllib3-layer"    # Default: urllib3-layer
export TABLE_NAME="SlackNotifierDDB"       # Default: SlackNotifierDDB
```

## Configure CloudWatch Log Subscription

Set up a CloudWatch log subscription filter to trigger your Lambda function when RDS logs are received. This step connects your RDS error logs to the Lambda function for processing.

## Dependencies

- **boto3** - AWS SDK (included in Lambda runtime)
- **urllib3** - HTTP client library (provided via Lambda layer)


## Troubleshooting

### Common Issues and Solutions

**Deployment Issues:**
- If role creation fails, wait a few seconds and retry
- Ensure your AWS CLI has sufficient permissions
- Verify Python 3.12 is installed and accessible
- Check that zip utility is available

**Runtime Issues:**
- Check CloudWatch Logs for function execution details: `aws logs tail /aws/lambda/SlackNotifier --follow`
- Verify environment variables are set correctly
- Ensure the Slack webhook URL is valid and accessible
- Confirm DynamoDB table exists and Lambda has permissions

**Subscription Filter Issues:**
- Verify subscription filter exists: `aws logs describe-subscription-filters --log-group-name YOUR_LOG_GROUP`
- Check Lambda function is being invoked: Monitor CloudWatch metrics and logs
- Monitor Lambda logs for processing activity: `aws logs tail /aws/lambda/SlackNotifier --follow`

**Virtual Environment Issues:**
- If venv removal fails during cleanup, manually run: `chmod -R u+w venv && rm -rf venv`
- Ensure Python 3.12 is properly installed before deployment

**Permission Issues:**
- Verify AWS credentials have required permissions (see Prerequisites section)
- Check IAM role has proper trust relationships and policies attached

## Cleanup

Use the undeploy script to safely remove all AWS resources:

```bash
./scripts/undeploy.sh
```

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

