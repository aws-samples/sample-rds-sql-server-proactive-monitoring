import json
import gzip
import os
import urllib3
import re
import boto3
import time
from typing import Dict, Any
import base64
from botocore.exceptions import ClientError

def decode_cloudwatch_log(event: Dict[str, Any]) -> Dict[str, Any]:
    # CloudWatch Logs data is base64 encoded and compressed
    compressed_payload = base64.b64decode(event['awslogs']['data'])
    uncompressed_payload = gzip.decompress(compressed_payload)
    log_data = json.loads(uncompressed_payload)
    return log_data

def post_to_slack(message: str) -> None:
    slack_webhook_url = os.environ['SLACK_WEBHOOK_URL']
    
    slack_message = {
        "text": message
    }
    encoded_msg = json.dumps(slack_message).encode('utf-8')
    with urllib3.PoolManager() as http:
        resp = http.request('POST', slack_webhook_url,
                       body=encoded_msg,
                       headers={'Content-Type': 'application/json'})
    
    if resp.status != 200:
        raise ValueError(f'Request to Slack returned status {resp.status}')

def extract_timestamp(message: str) -> str:
    timestamp_pattern = r'(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)'
    match = re.search(timestamp_pattern, message)
    if match:
        return match.group(1)
    return ""

def parse_sql_error(message: str) -> Dict[str, Any]:
    print(f"Message: {message}")
    message_text = message.strip()
    
    log_timestamp = extract_timestamp(message_text)
    
    # Pattern 1
    pattern1 = r'Msg\s+(\d+),\s+Level\s+(\d+),\s+State\s+(\d+),\s+Server\s+([^,]+),\s+Line\s+(\d+)\s+(.+)'
    match = re.search(pattern1, message_text)
    
    if match:
        return {
            'error_number': int(match.group(1)),
            'level': int(match.group(2)),
            'state': int(match.group(3)),
            'line': int(match.group(5)),
            'message': match.group(6).strip(),
            'full_message': message,
            'log_timestamp': log_timestamp,
            'is_complete': True  # Pattern 1 includes the message in the same line
        }
    
    # Pattern 2
    pattern2 = r'Error:\s+(\d+),\s+Severity:\s+(\d+),\s+State:\s+(\d+)'
    match = re.search(pattern2, message_text)
    
    if match:
        return {
            'error_number': int(match.group(1)),
            'level': int(match.group(2)),  # Severity in this format
            'state': int(match.group(3)),
            'line': 0,     # Line number not available in this format
            'message': "",  # Empty message, will be filled by next invocation
            'full_message': message,
            'log_timestamp': log_timestamp,
            'is_complete': False  # Always incomplete for pattern 2
        }
    
    return None

def get_dynamodb_table():
    """Get reference to the pre-existing DynamoDB table"""
    dynamodb = boto3.resource('dynamodb')
    table_name = os.environ.get('DYNAMODB_TABLE_NAME', 'SlackNotifierDDB')
    return dynamodb.Table(table_name)

def store_in_dynamodb(error_data: Dict[str, Any]) -> bool:
    # Get table reference
    table = get_dynamodb_table()
    try:
        current_time = int(error_data.get('timestamp', 0))
        error_data['timestamp'] = current_time
        
        from datetime import datetime, timezone
        error_data['utc_time'] = datetime.now(timezone.utc).isoformat()
        
        ttl_hours = int(os.environ.get('TTL_HOURS', 48))
        
        current_time_seconds = current_time // 1000 if current_time > 1000000000000 else current_time
        
        error_data['expiry_time'] = current_time_seconds + (ttl_hours * 3600)  # Convert hours to seconds
        
        error_data['last_slack_notification'] = 0  # Initialize to 0 (never sent)
        error_data['slack_message_sent'] = False
        
        table.put_item(Item=error_data)
        return True
    except ClientError as e:
        print(f"Error storing data in DynamoDB: {str(e)}")
        return False

def should_send_slack_notification(error_number: int, level: int, state: int) -> bool:
    table = get_dynamodb_table()
    
    try:
        # Query DynamoDB for entries with matching error_number, level, and state
        response = table.query(
            KeyConditionExpression=boto3.dynamodb.conditions.Key('error_number').eq(error_number),
            FilterExpression=boto3.dynamodb.conditions.Attr('level').eq(level) & boto3.dynamodb.conditions.Attr('state').eq(state),
            ScanIndexForward=False,
        )
        
        # If no records found, we should send notification
        if response.get('Count', 0) == 0:
            print(f"No previous records for error {error_number} with level {level} and state {state}, sending notification")
            return True
        
        most_recent_notification = 0
        for item in response.get('Items', []):
            notification_time = item.get('last_slack_notification', 0)
            if notification_time > most_recent_notification:
                most_recent_notification = notification_time
        
        cooldown_minutes = int(os.environ.get('NOTIFICATION_COOLDOWN_MINUTES', 15))
        cooldown_seconds = cooldown_minutes * 60
        
        current_time = int(time.time())
        if current_time - most_recent_notification > cooldown_seconds:
            print(f"Cooldown period passed for error {error_number} (level {level}, state {state}), sending notification")
            return True
        else:
            print(f"Cooldown period NOT passed for error {error_number} (level {level}, state {state}), skipping notification")
            return False        
    except ClientError as e:
        print(f"Error checking notification status: {str(e)}")
        # Default to sending notification if there's an error
        return True

def update_slack_notification_status(error_number: int, timestamp: int) -> None:
    table = get_dynamodb_table()
    
    try:
        current_time = int(time.time())
        
        response = table.update_item(
            Key={
                'error_number': error_number,
                'timestamp': timestamp
            },
            UpdateExpression="SET last_slack_notification = :time, slack_message_sent = :sent",
            ExpressionAttributeValues={
                ':time': current_time,
                ':sent': True
            }
        )    
        print(f"Updated notification status for error {error_number}")
    except ClientError as e:
        print(f"Error updating notification status: {str(e)}")

def find_incomplete_error() -> Dict[str, Any]:
    table = get_dynamodb_table()
    print(f"Looking for incomplete errors in table: {table.table_name}")
    
    try:
        all_incomplete_items = []
        last_evaluated_key = None
        
        while True:
            scan_params = {
                'FilterExpression': boto3.dynamodb.conditions.Attr('is_complete').eq(False)
            }
            
            if last_evaluated_key:
                scan_params['ExclusiveStartKey'] = last_evaluated_key
            
            response = table.scan(**scan_params)
            
            if response.get('Items'):
                all_incomplete_items.extend(response['Items'])
            
            last_evaluated_key = response.get('LastEvaluatedKey')
            if not last_evaluated_key:
                break
        
        print(f"Found {len(all_incomplete_items)} incomplete errors")
        
        if all_incomplete_items:
            # Sort items by timestamp in descending order to get the most recent one
            sorted_items = sorted(all_incomplete_items, key=lambda x: x.get('timestamp', 0), reverse=True)
            return sorted_items[0]
        return None
    except ClientError as e:
        print(f"Error scanning for incomplete errors: {str(e)}")
        return None

def clean_error_message(message: str) -> str:
    timestamp_pattern = r'^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+spid\d+\s+'
    return re.sub(timestamp_pattern, '', message).strip()

def update_error_with_description(error_item: Dict[str, Any], description: str) -> Dict[str, Any]:
    table = get_dynamodb_table()
    
    cleaned_description = clean_error_message(description)
    
    try:
        # Update the error with the cleaned description and mark as complete
        response = table.update_item(
            Key={
                'error_number': error_item['error_number'],
                'timestamp': error_item['timestamp']
            },
            UpdateExpression="SET message = :desc, is_complete = :complete",
            ExpressionAttributeValues={
                ':desc': cleaned_description,
                ':complete': True
            },
            ReturnValues="ALL_NEW"
        )
        
        print(f"Updated error with description: {response}")
        return response.get('Attributes', {})
    except ClientError as e:
        print(f"Error updating error with description: {str(e)}")
        return None

def should_ignore_message(message: str) -> bool:
    # List of patterns to ignore
    ignore_patterns = [
        "Attempting to cycle error log",
        "Logging SQL Server messages in file",
        "DBCC CHECKDB .* found 0 errors and repaired 0 errors",
        "This is an informational message only",
        "The error log has been reinitialized",
        "The last error 0 was within the time threshold for the duplicate count",
        "DBCC execution completed. If DBCC printed error messages, contact your system administrator.",
        "DBCC STDOUT:",
        "DBCC STDERR:",
        "DBCC has extra input",
        "DBCC is not currently processing any command"
    ]
    
    # Check if message contains any of the ignore patterns
    for pattern in ignore_patterns:
        if re.search(pattern, message, re.IGNORECASE):
            print(f"Ignoring message due to pattern match: {message[:100]}...")
            return True
    
    return False

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    try:
        # Decode and decompress CloudWatch Logs data
        log_data = decode_cloudwatch_log(event)
        
        # Format the message for Slack
        log_group = log_data['logGroup']
        log_stream = log_data['logStream']

        # Process each log event
        for log_event in log_data['logEvents']:
            message_text = log_event['message']
            
            if should_ignore_message(message_text):
                print(f"Ignoring informational message: {message_text[:100]}...")
                continue
            
            error_data = parse_sql_error(message_text)
            
            if not error_data:
                # Check if this is a description for a duplicate error that we should ignore
                incomplete_error = find_incomplete_error()
                if incomplete_error:
                    print(f"Found incomplete error: {incomplete_error['error_number']}")
                    print(f"Adding description: {message_text}")
                else:
                    print("No incomplete error found to match with this description")
                    continue
                
                # Update the error with the description
                updated_error = update_error_with_description(incomplete_error, message_text)
                if updated_error:
                    # Check if we should send a notification
                    if should_send_slack_notification(updated_error['error_number'], updated_error['level'], updated_error['state']):
                        # Format message for Slack with the updated error
                        message = (
                            f"*SQL Error:* {updated_error['error_number']}\n"
                            f"*Level:* {updated_error['level']}\n"
                            f"*State:* {updated_error['state']}\n"
                            f"*Timestamp:* {updated_error.get('log_timestamp', '')}\n"
                            f"*Message:* {updated_error['message']}\n"
                            f"*Log Group:* {updated_error['log_group']}\n"
                            f"*Log Stream:* {updated_error['log_stream']}"
                        )                    
                        # Send to Slack
                        try:
                            post_to_slack(message)
                            update_slack_notification_status(updated_error['error_number'], updated_error['timestamp'])
                        except ValueError as e:
                            print(f"Error sending message to Slack: {str(e)}")
                    else:
                        print(f"Skipping Slack notification for error {updated_error['error_number']} due to cooldown period")
                continue  # Skip further processing for this message
                
            # Parse the SQL error from the log message
            error_data = parse_sql_error(message_text)
            print(f"Error data: {error_data}")
            
            if error_data:
                # Add log metadata
                error_data['log_group'] = log_group
                error_data['log_stream'] = log_stream
                error_data['timestamp'] = log_event['timestamp']
                
                store_in_dynamodb(error_data)
                
                if error_data.get('is_complete', False) and should_send_slack_notification(error_data['error_number'], error_data['level'], error_data['state']):
                    # Format message for Slack
                    message = (
                        f"*SQL Error:* {error_data['error_number']}\n"
                        f"*Level:* {error_data['level']}\n"
                        f"*State:* {error_data['state']}\n"
                        f"*Timestamp:* {error_data.get('log_timestamp', '')}\n"
                        f"*Message:* {error_data['message']}\n"
                        f"*Log Group:* {log_group}\n"
                        f"*Log Stream:* {log_stream}"
                    )
                    # Send to Slack
                    try:
                        post_to_slack(message)
                        # Update notification status
                        update_slack_notification_status(error_data['error_number'], error_data['timestamp'])
                    except ValueError as e:
                        print(f"Error sending message to Slack: {str(e)}")
                elif not error_data.get('is_complete', False):
                    print(f"Error is incomplete, waiting for description: {error_data['error_number']}")
                else:
                    print(f"Skipping Slack notification for error {error_data['error_number']} due to cooldown period")                
            else:
                # For non-SQL Server errors, just log them
                print(f"Non-SQL Server error format: {message_text}")
        return {
            'statusCode': 200,
            'body': json.dumps('Successfully processed logs')
        }
        
    except Exception as e:
        print(f"Error processing log: {str(e)}")
        raise