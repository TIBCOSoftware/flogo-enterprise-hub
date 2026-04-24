package awssignaturev4

import (
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

func TestRegister(t *testing.T) {
	ref := activity.GetRef(&AWSSignatureV4Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestMetadata(t *testing.T) {
	act := &AWSSignatureV4Activity{}
	md := act.Metadata()
	assert.NotNil(t, md)
}

func TestEvalSuccess(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	// Set inputs using the new structure
	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")
	tc.SetInput("payload", "")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	// Verify success
	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	// Verify outputs with new field names
	authHeader := tc.GetOutput("authorizationHeader")
	assert.NotEmpty(t, authHeader)

	xAmzDate := tc.GetOutput("xAmzDate")
	assert.NotEmpty(t, xAmzDate)
	assert.Len(t, xAmzDate.(string), 16) // Format: 20230815T120000Z

	xAmzContentSha256 := tc.GetOutput("xAmzContentSha256")
	assert.NotEmpty(t, xAmzContentSha256)
	assert.Len(t, xAmzContentSha256.(string), 64) // SHA256 hex length

	allHeaders := tc.GetOutput("allHeaders")
	assert.NotNil(t, allHeaders)

	headers := allHeaders.(map[string]interface{})
	assert.Contains(t, headers, "Authorization")
	assert.Contains(t, headers, "X-Amz-Date")
	assert.Contains(t, headers, "X-Amz-Content-Sha256")
}

func TestEvalMissingAccessKey(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	// Missing accessKeyId
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	// Verify failure
	success := tc.GetOutput("success")
	assert.False(t, success.(bool))

	errorCode := tc.GetOutput("errorCode")
	assert.Equal(t, "AWS-SIGNATUREV4-4001", errorCode.(string))

	errorMessage := tc.GetOutput("errorMessage")
	assert.Contains(t, errorMessage.(string), "Access Key ID")
}

func TestEvalInvalidURL(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "://invalid-url-format")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	// Verify failure
	success := tc.GetOutput("success")
	assert.False(t, success.(bool))

	errorCode := tc.GetOutput("errorCode")
	assert.Equal(t, "AWS-SIGNATUREV4-4007", errorCode.(string))
}

func TestEvalInvalidHTTPMethod(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "INVALID")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	// Verify failure
	success := tc.GetOutput("success")
	assert.False(t, success.(bool))

	errorCode := tc.GetOutput("errorCode")
	assert.Equal(t, "AWS-SIGNATUREV4-4010", errorCode.(string))
}

func TestEvalWithSessionToken(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "ASIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("sessionToken", "AQoEXAMPLEH4aoAH0gNCAPyJxz4BlCFFxWNE1OPTgk5TthT+FvwqnKwRcOIfrRh3c/...")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	// Check that session token is included in output
	xAmzSecurityToken := tc.GetOutput("xAmzSecurityToken")
	assert.NotEmpty(t, xAmzSecurityToken)

	allHeaders := tc.GetOutput("allHeaders")
	headers := allHeaders.(map[string]interface{})
	assert.Contains(t, headers, "X-Amz-Security-Token")
}

func TestEvalWithAdditionalHeaders(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "PUT")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")
	tc.SetInput("payload", "test content")
	tc.SetInput("headers", map[string]interface{}{
		"Content-Type":        "text/plain",
		"X-Amz-Storage-Class": "STANDARD",
	})

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	allHeaders := tc.GetOutput("allHeaders")
	headers := allHeaders.(map[string]interface{})
	assert.Contains(t, headers, "Content-Type")
	assert.Contains(t, headers, "X-Amz-Storage-Class")
}

func TestEvalWithValidTimestamp(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")
	tc.SetInput("timestamp", "2023-08-15T12:00:00Z")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	// Verify timestamp is used
	xAmzDate := tc.GetOutput("xAmzDate")
	assert.Equal(t, "20230815T120000Z", xAmzDate.(string))
}

func TestEvalInvalidTimestamp(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")
	tc.SetInput("timestamp", "invalid-timestamp")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	// Verify failure
	success := tc.GetOutput("success")
	assert.False(t, success.(bool))

	errorCode := tc.GetOutput("errorCode")
	assert.Equal(t, "AWS-SIGNATUREV4-4008", errorCode.(string))

	errorMessage := tc.GetOutput("errorMessage")
	assert.Contains(t, errorMessage.(string), "Invalid timestamp format")
}

func TestEvalWithQueryParameters(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object?response-content-type=application/json&response-content-disposition=attachment")
	tc.SetInput("payload", "")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	// Verify outputs are not empty
	authHeader := tc.GetOutput("authorizationHeader")
	assert.NotEmpty(t, authHeader)

	// Check that canonical request includes query parameters
	canonicalRequest := tc.GetOutput("canonicalRequest")
	assert.Contains(t, canonicalRequest.(string), "response-content-disposition=attachment")
	assert.Contains(t, canonicalRequest.(string), "response-content-type=application%2Fjson")
}

func TestEvalWithEmptyPayload(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	tc.SetInput("accessKeyId", "AKIAIOSFODNN7EXAMPLE")
	tc.SetInput("secretAccessKey", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
	tc.SetInput("region", "us-east-1")
	tc.SetInput("service", "s3")
	tc.SetInput("httpMethod", "GET")
	tc.SetInput("url", "https://s3.amazonaws.com/bucket/object")
	tc.SetInput("payload", "")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	success := tc.GetOutput("success")
	assert.True(t, success.(bool))

	// Verify SHA256 hash of empty string
	xAmzContentSha256 := tc.GetOutput("xAmzContentSha256")
	assert.Equal(t, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", xAmzContentSha256.(string))
}
