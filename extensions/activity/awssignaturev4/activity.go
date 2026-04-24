/*
 * Copyright © 2024. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */

package awssignaturev4

import (
	"crypto/hmac"
	"crypto/sha256"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/support/log"
)

func init() {
	_ = activity.Register(&AWSSignatureV4Activity{}, New)
}

var activityLog = log.ChildLogger(log.RootLogger(), "aws-activity-signaturev4")

var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

type AWSSignatureV4Activity struct {
}

func New(ctx activity.InitContext) (activity.Activity, error) {
	act := &AWSSignatureV4Activity{}
	return act, nil
}

func (a *AWSSignatureV4Activity) Metadata() *activity.Metadata {
	return activityMd
}

func (a *AWSSignatureV4Activity) Eval(context activity.Context) (done bool, err error) {

	input := &Input{}

	err = context.GetInputObject(input)
	if err != nil {
		return false, err
	}

	activityLog.Info("Executing AWS Signature V4 activity")
	activityLog.Debugf("Request details - Method: %s, URL: %s, Service: %s, Region: %s",
		input.HTTPMethod, input.URL, input.Service, input.Region)

	// Initialize output with error state
	output := &Output{
		Success:      false,
		ErrorDetails: make(map[string]interface{}),
	}

	// Validate required settings
	if strings.TrimSpace(input.AccessKeyID) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4001"
		output.ErrorMessage = "Access Key ID is not configured or is empty"
		output.ErrorDetails["field"] = "accessKeyId"
		output.ErrorDetails["category"] = "configuration"
		output.ErrorDetails["suggestion"] = "Configure the AWS Access Key ID in activity settings"

		activityLog.Errorf("Configuration error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil // Return success but with error output
	}

	if strings.TrimSpace(input.SecretAccessKey) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4002"
		output.ErrorMessage = "Secret Access Key is not configured or is empty"
		output.ErrorDetails["field"] = "secretAccessKey"
		output.ErrorDetails["category"] = "configuration"
		output.ErrorDetails["suggestion"] = "Configure the AWS Secret Access Key in activity settings"

		activityLog.Errorf("Configuration error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	if strings.TrimSpace(input.Region) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4003"
		output.ErrorMessage = "AWS Region is not configured or is empty"
		output.ErrorDetails["field"] = "region"
		output.ErrorDetails["category"] = "configuration"
		output.ErrorDetails["suggestion"] = "Configure the AWS Region (e.g., us-east-1, us-west-2) in activity settings"

		activityLog.Errorf("Configuration error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	if strings.TrimSpace(input.Service) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4004"
		output.ErrorMessage = "AWS Service is not configured or is empty"
		output.ErrorDetails["field"] = "service"
		output.ErrorDetails["category"] = "configuration"
		output.ErrorDetails["suggestion"] = "Configure the AWS Service name (e.g., s3, ec2, lambda, dynamodb) in activity settings"

		activityLog.Errorf("Configuration error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Validate required inputs
	if strings.TrimSpace(input.HTTPMethod) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4005"
		output.ErrorMessage = "HTTP Method is not provided or is empty"
		output.ErrorDetails["field"] = "httpMethod"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["suggestion"] = "Provide a valid HTTP method (GET, POST, PUT, DELETE, etc.)"

		activityLog.Errorf("Input error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	if strings.TrimSpace(input.URL) == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4006"
		output.ErrorMessage = "URL is not provided or is empty"
		output.ErrorDetails["field"] = "url"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["suggestion"] = "Provide a complete URL including scheme, host, and path"

		activityLog.Errorf("Input error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Validate HTTP method
	validMethods := map[string]bool{
		"GET": true, "POST": true, "PUT": true, "DELETE": true, "HEAD": true, "PATCH": true, "OPTIONS": true,
	}
	if !validMethods[strings.ToUpper(input.HTTPMethod)] {
		output.ErrorCode = "AWS-SIGNATUREV4-4010"
		output.ErrorMessage = fmt.Sprintf("Invalid HTTP method: %s", input.HTTPMethod)
		output.ErrorDetails["field"] = "httpMethod"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["provided"] = input.HTTPMethod
		output.ErrorDetails["validMethods"] = []string{"GET", "POST", "PUT", "DELETE", "HEAD", "PATCH", "OPTIONS"}
		output.ErrorDetails["suggestion"] = "Use a valid HTTP method"

		activityLog.Errorf("Input validation error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Parse URL
	parsedURL, err := url.Parse(input.URL)
	if err != nil {
		output.ErrorCode = "AWS-SIGNATUREV4-4007"
		output.ErrorMessage = fmt.Sprintf("Invalid URL: %s", err.Error())
		output.ErrorDetails["field"] = "url"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["provided"] = input.URL
		output.ErrorDetails["parseError"] = err.Error()
		output.ErrorDetails["suggestion"] = "Provide a valid URL with scheme (https://), host, and path"

		activityLog.Errorf("URL parsing error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Validate URL scheme
	if parsedURL.Scheme != "https" && parsedURL.Scheme != "http" {
		output.ErrorCode = "AWS-SIGNATUREV4-4011"
		output.ErrorMessage = fmt.Sprintf("Invalid URL scheme: %s. AWS recommends https", parsedURL.Scheme)
		output.ErrorDetails["field"] = "url"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["provided"] = input.URL
		output.ErrorDetails["scheme"] = parsedURL.Scheme
		output.ErrorDetails["suggestion"] = "Use https:// scheme for AWS API calls (http is allowed but not recommended)"

		activityLog.Warnf("URL validation warning: %s", output.ErrorMessage)
		// Don't return error for http, just warn
		if parsedURL.Scheme != "http" {
			context.SetOutputObject(output)
			return true, nil
		}
	}

	// Validate host
	if parsedURL.Host == "" {
		output.ErrorCode = "AWS-SIGNATUREV4-4012"
		output.ErrorMessage = "URL host is missing"
		output.ErrorDetails["field"] = "url"
		output.ErrorDetails["category"] = "input"
		output.ErrorDetails["provided"] = input.URL
		output.ErrorDetails["suggestion"] = "Provide a complete URL with hostname (e.g., https://s3.amazonaws.com/bucket/key)"

		activityLog.Errorf("URL validation error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Get timestamp
	var timestamp time.Time
	if input.Timestamp != "" {
		timestamp, err = time.Parse(time.RFC3339, input.Timestamp)
		if err != nil {
			output.ErrorCode = "AWS-SIGNATUREV4-4008"
			output.ErrorMessage = fmt.Sprintf("Invalid timestamp format: %s", err.Error())
			output.ErrorDetails["field"] = "timestamp"
			output.ErrorDetails["category"] = "input"
			output.ErrorDetails["provided"] = input.Timestamp
			output.ErrorDetails["expectedFormat"] = "RFC3339 (2006-01-02T15:04:05Z07:00)"
			output.ErrorDetails["parseError"] = err.Error()
			output.ErrorDetails["suggestion"] = "Provide timestamp in RFC3339 format or leave empty for current time"

			activityLog.Errorf("Timestamp parsing error: %s", output.ErrorMessage)
			context.SetOutputObject(output)
			return true, nil
		}
	} else {
		timestamp = time.Now().UTC()
	}

	// Generate AWS Signature V4
	activityLog.Debug("Starting AWS Signature V4 generation process")
	signature, err := a.generateSignature(input, parsedURL, timestamp)
	if err != nil {
		output.ErrorCode = "AWS-SIGNATUREV4-4009"
		output.ErrorMessage = fmt.Sprintf("Failed to generate signature: %s", err.Error())
		output.ErrorDetails["category"] = "signature"
		output.ErrorDetails["signatureError"] = err.Error()
		output.ErrorDetails["suggestion"] = "Check canonical request and string-to-sign outputs for debugging"

		activityLog.Errorf("Signature generation error: %s", output.ErrorMessage)
		context.SetOutputObject(output)
		return true, nil
	}

	// Success case
	output.Success = true
	output.AuthorizationHeader = signature.AuthorizationHeader
	output.XAmzDate = signature.XAmzDate
	output.XAmzContentSha256 = signature.XAmzContentSha256
	output.XAmzSecurityToken = signature.XAmzSecurityToken
	output.AllHeaders = signature.AllHeaders
	output.CanonicalRequest = signature.CanonicalRequest
	output.StringToSign = signature.StringToSign
	output.ErrorCode = ""
	output.ErrorMessage = ""
	output.ErrorDetails = make(map[string]interface{})

	err = context.SetOutputObject(output)
	if err != nil {
		return false, fmt.Errorf("error setting output for Activity [%s]: %s", context.Name(), err.Error())
	}

	activityLog.Infof("Successfully generated AWS Signature V4 for %s %s", input.HTTPMethod, input.URL)
	return true, nil
}

// SignatureResult holds the generated signature components
type SignatureResult struct {
	AuthorizationHeader string
	XAmzDate            string
	XAmzContentSha256   string
	XAmzSecurityToken   string
	AllHeaders          map[string]interface{}
	CanonicalRequest    string
	StringToSign        string
}

func (a *AWSSignatureV4Activity) generateSignature(input *Input, parsedURL *url.URL, timestamp time.Time) (*SignatureResult, error) {
	activityLog.Debug("Step 1: Calculating content SHA256")
	// Step 1: Calculate content SHA256
	contentSha256 := a.sha256Hash(input.Payload)
	activityLog.Debugf("Content SHA256: %s", contentSha256)

	activityLog.Debug("Step 2: Creating canonical request")
	// Step 2: Create canonical request
	canonicalRequest, signedHeaders, err := a.createCanonicalRequest(input, parsedURL, timestamp)
	if err != nil {
		return nil, err
	}
	activityLog.Debugf("Canonical request created with signed headers: %s", signedHeaders)

	activityLog.Debug("Step 3: Creating string to sign")
	// Step 3: Create string to sign
	stringToSign := a.createStringToSign(input, canonicalRequest, timestamp)

	activityLog.Debug("Step 4: Calculating signature")
	// Step 4: Calculate signature
	signature := a.calculateSignature(input, stringToSign, timestamp)

	activityLog.Debug("Step 5: Creating authorization header")
	// Step 5: Create authorization header
	authorizationHeader := a.createAuthorizationHeader(input, signedHeaders, signature, timestamp)

	activityLog.Debug("Step 6: Creating date header")
	// Step 6: Create date header
	xAmzDate := timestamp.Format("20060102T150405Z")

	activityLog.Debug("Step 7: Assembling all headers")
	// Step 7: Create all headers map
	allHeaders := make(map[string]interface{})
	allHeaders["Authorization"] = authorizationHeader
	allHeaders["X-Amz-Date"] = xAmzDate
	allHeaders["X-Amz-Content-Sha256"] = contentSha256

	// Add session token if present
	xAmzSecurityToken := ""
	if input.SessionToken != "" {
		xAmzSecurityToken = input.SessionToken
		allHeaders["X-Amz-Security-Token"] = xAmzSecurityToken
	}

	// Add any additional headers from input
	if input.Headers != nil {
		for key, value := range input.Headers {
			// Don't override specific AWS authentication headers
			lowerKey := strings.ToLower(key)
			if lowerKey != "authorization" &&
				lowerKey != "x-amz-date" &&
				lowerKey != "x-amz-security-token" &&
				lowerKey != "x-amz-content-sha256" {
				allHeaders[key] = value
			}
		}
	}

	return &SignatureResult{
		AuthorizationHeader: authorizationHeader,
		XAmzDate:            xAmzDate,
		XAmzContentSha256:   contentSha256,
		XAmzSecurityToken:   xAmzSecurityToken,
		AllHeaders:          allHeaders,
		CanonicalRequest:    canonicalRequest,
		StringToSign:        stringToSign,
	}, nil
}

func (a *AWSSignatureV4Activity) createCanonicalRequest(input *Input, parsedURL *url.URL, timestamp time.Time) (string, string, error) {
	// HTTP Method
	method := strings.ToUpper(input.HTTPMethod)

	// Canonical URI
	canonicalURI := parsedURL.Path
	if canonicalURI == "" {
		canonicalURI = "/"
	}

	// Canonical Query String
	canonicalQueryString := ""
	if parsedURL.RawQuery != "" {
		queryParams, err := url.ParseQuery(parsedURL.RawQuery)
		if err != nil {
			return "", "", fmt.Errorf("failed to parse query parameters: %s", err.Error())
		}

		var keys []string
		for k := range queryParams {
			keys = append(keys, k)
		}
		sort.Strings(keys)

		var queryParts []string
		for _, k := range keys {
			for _, v := range queryParams[k] {
				queryParts = append(queryParts, url.QueryEscape(k)+"="+url.QueryEscape(v))
			}
		}
		canonicalQueryString = strings.Join(queryParts, "&")
	}

	// Canonical Headers
	headers := make(map[string]string)
	headers["host"] = parsedURL.Host
	headers["x-amz-date"] = timestamp.Format("20060102T150405Z")
	headers["x-amz-content-sha256"] = a.sha256Hash(input.Payload)

	// Add session token if present
	if input.SessionToken != "" {
		headers["x-amz-security-token"] = input.SessionToken
	}

	// Add additional headers from input
	if input.Headers != nil {
		for key, value := range input.Headers {
			strValue, err := coerce.ToString(value)
			if err != nil {
				activityLog.Warnf("Failed to convert header value for key '%s': %s", key, err.Error())
				continue
			}

			// Validate header name
			if strings.TrimSpace(key) == "" {
				activityLog.Warnf("Skipping empty header name")
				continue
			}

			headers[strings.ToLower(key)] = strings.TrimSpace(strValue)
		}
	}

	var headerKeys []string
	for k := range headers {
		headerKeys = append(headerKeys, k)
	}
	sort.Strings(headerKeys)

	var canonicalHeadersParts []string
	for _, k := range headerKeys {
		canonicalHeadersParts = append(canonicalHeadersParts, k+":"+headers[k])
	}
	canonicalHeaders := strings.Join(canonicalHeadersParts, "\n") + "\n"

	// Signed Headers
	signedHeaders := strings.Join(headerKeys, ";")

	// Payload Hash
	payloadHash := a.sha256Hash(input.Payload)

	// Create canonical request
	canonicalRequest := method + "\n" +
		canonicalURI + "\n" +
		canonicalQueryString + "\n" +
		canonicalHeaders + "\n" +
		signedHeaders + "\n" +
		payloadHash

	return canonicalRequest, signedHeaders, nil
}

func (a *AWSSignatureV4Activity) createStringToSign(input *Input, canonicalRequest string, timestamp time.Time) string {
	algorithm := "AWS4-HMAC-SHA256"
	requestDateTime := timestamp.Format("20060102T150405Z")
	credentialScope := timestamp.Format("20060102") + "/" + input.Region + "/" + input.Service + "/aws4_request"
	hashedCanonicalRequest := a.sha256Hash(canonicalRequest)

	stringToSign := algorithm + "\n" +
		requestDateTime + "\n" +
		credentialScope + "\n" +
		hashedCanonicalRequest

	return stringToSign
}

func (a *AWSSignatureV4Activity) calculateSignature(input *Input, stringToSign string, timestamp time.Time) string {
	dateKey := a.hmacSHA256([]byte("AWS4"+input.SecretAccessKey), timestamp.Format("20060102"))
	regionKey := a.hmacSHA256(dateKey, input.Region)
	serviceKey := a.hmacSHA256(regionKey, input.Service)
	signingKey := a.hmacSHA256(serviceKey, "aws4_request")
	signature := a.hmacSHA256(signingKey, stringToSign)

	return fmt.Sprintf("%x", signature)
}

func (a *AWSSignatureV4Activity) createAuthorizationHeader(input *Input, signedHeaders, signature string, timestamp time.Time) string {
	algorithm := "AWS4-HMAC-SHA256"
	credential := input.AccessKeyID + "/" + timestamp.Format("20060102") + "/" + input.Region + "/" + input.Service + "/aws4_request"

	authorizationHeader := algorithm + " " +
		"Credential=" + credential + ", " +
		"SignedHeaders=" + signedHeaders + ", " +
		"Signature=" + signature

	return authorizationHeader
}

func (a *AWSSignatureV4Activity) sha256Hash(data string) string {
	hash := sha256.Sum256([]byte(data))
	return fmt.Sprintf("%x", hash)
}

func (a *AWSSignatureV4Activity) hmacSHA256(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}
