# AWS Signature V4 Generator Activity

A Flogo activity that generates AWS Signature Version 4 authentication headers for REST API calls to AWS services. This activity implements the complete AWS Signature Version 4 signing process, enabling secure authenticated requests to AWS APIs.

## Overview

This activity provides a complete implementation of the AWS Signature Version 4 authentication scheme. It generates all necessary headers required for authenticating REST API calls to AWS services including S3, SQS, DynamoDB, Lambda, and others. The activity handles the complex cryptographic signing process and provides comprehensive error handling with detailed debugging information.

## Features

- **Complete AWS Signature V4 Implementation**: Full support for the AWS Signature Version 4 authentication scheme
- **Multi-Service Support**: Works with all AWS services that support Signature V4 (S3, SQS, DynamoDB, Lambda, EC2, etc.)
- **Session Token Support**: Handles temporary credentials from AWS STS
- **Custom Headers Support**: Allows additional headers to be included in the signature calculation
- **Comprehensive Validation**: Input validation with detailed error messages
- **Debug Support**: Provides canonical request and string-to-sign for debugging



## Configurations

### Inputs

| Name | Type | Required | Description |
|------|------|----------|-------------|
| accessKeyId | string | true | AWS Access Key ID |
| secretAccessKey | string | true | AWS Secret Access Key |
| region | string | true | AWS region (e.g., us-east-1, eu-west-1) |
| service | string | true | AWS service name (e.g., s3, sqs, dynamodb, lambda) |
| sessionToken | string | false | AWS Session Token (required for temporary credentials from STS) |
| httpMethod | string | true | HTTP method (GET, POST, PUT, DELETE, HEAD, PATCH, OPTIONS) |
| url | string | true | Complete URL including scheme, host, path, and query parameters |
| payload | string | false | Request body content (empty string for GET requests) |
| headers | object | false | Additional headers to include in the request |
| timestamp | string | false | ISO 8601 timestamp (RFC3339 format). If not provided, current time is used |

### Outputs

| Name | Type | Description |
|------|------|-------------|
| success | boolean | Indicates whether signature generation was successful |
| authorizationHeader | string | Complete AWS Authorization header value |
| xAmzDate | string | AWS X-Amz-Date header value |
| xAmzContentSha256 | string | AWS X-Amz-Content-Sha256 header value |
| xAmzSecurityToken | string | AWS X-Amz-Security-Token header value (when using session token) |
| allHeaders | object | Complete set of headers needed for AWS request |
| canonicalRequest | string | AWS canonical request string (for debugging) |
| stringToSign | string | AWS string-to-sign (for debugging) |
| errorCode | string | Error code for failed operations |
| errorMessage | string | Error message for failed operations |
| errorDetails | object | Additional error context and suggestions |


## Configuration Examples

### SQS Delete Queue  Msg Request
```json
          {
            "id": "AWSSignatureV4Generator1",
            "name": "AWSSignatureV4Generator1",
            "description": "Generates AWS Signature Version 4 authentication headers for REST API calls",
            "activity": {
              "ref": "#awssignaturev4",
              "input": {
                "accessKeyId": "AKIAIOSFODNN7EXAMPLE",
                "secretAccessKey": "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLE",
                "region": "eu-central-1",
                "service": "sqs",
                "sessionToken": "AKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLEAKIAIOSFODNN7EXAMPLE",
                "httpMethod": "POST",
                "url": "https://sqs.eu-central-1.amazonaws.com/accountId/queue-Name",
                "payload": "Version=2012-11-05&Action=DeleteMessage&ReceiptHandle=\",$flow.Message[0].ReceiptHandle)",
                "timestamp": ""
              },
              "output": {
                "success": false
              }
            }
          }
```

### S3 Object PUT Request with Custom Headers
```json
{
  "id": "aws_sign_s3_put",
  "name": "Sign S3 PUT Request",
  "activity": {
    "ref": "github.com/mpandav-tibco/flogo-extensions/activity/awssignaturev4",
    "input": {
      "accessKeyId": "AKIAIOSFODNN7EXAMPLE",
      "secretAccessKey": "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
      "region": "us-east-1",
      "service": "s3",
      "httpMethod": "PUT",
      "url": "https://s3.amazonaws.com/bucket-name/object-key",
      "payload": "file content here",
      "headers": {
        "Content-Type": "text/plain",
        "Content-Length": "17",
        "x-amz-storage-class": "STANDARD"
      }
    }
  }
}
```


## Debugging

The activity provides comprehensive debugging information:

### Canonical Request Output
The `canonicalRequest` output shows the exact request string used for signing:
```
POST
/bucket/object
param1=value1&param2=value2
host:s3.amazonaws.com
x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
x-amz-date:20230815T120000Z

host;x-amz-content-sha256;x-amz-date
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

### String to Sign Output
The `stringToSign` output shows the final string used for signature calculation:
```
AWS4-HMAC-SHA256
20230815T120000Z
20230815/us-east-1/s3/aws4_request
canonicalRequestHash
```

## Support

For issues and questions:
1. Check the error outputs for detailed error information
2. Enable debug logging for troubleshooting
3. Refer to AWS Signature Version 4 documentation
4. Submit issues through the project repository
