package awssignaturev4

import (
	"testing"

	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

func TestSQSSignatureGeneration(t *testing.T) {
	tc := test.NewActivityContext((&AWSSignatureV4Activity{}).Metadata())

	// Set inputs to match the SQS scenario from the error - WITHOUT Content-Type header
	tc.SetInput("accessKeyId", "ASIARC55DQGXWPCO6TV7")
	tc.SetInput("secretAccessKey", "example-secret-key") // Use a test key
	tc.SetInput("sessionToken", "test-session-token")
	tc.SetInput("region", "eu-central-1")
	tc.SetInput("service", "sqs")
	tc.SetInput("httpMethod", "POST")
	tc.SetInput("url", "https://sqs.eu-central-1.amazonaws.com/075021648303/odido-demo-detelte-ops")
	tc.SetInput("payload", "Version=2012-11-05&Action=DeleteMessage&ReceiptHandle=example-receipt")
	// No headers - this is the key fix!
	tc.SetInput("timestamp", "2025-08-27T08:07:52Z")

	act := &AWSSignatureV4Activity{}
	done, err := act.Eval(tc)

	assert.True(t, done)
	assert.Nil(t, err)

	if tc.GetOutput("success").(bool) {
		// Print debug information
		canonicalRequest := tc.GetOutput("canonicalRequest").(string)
		stringToSign := tc.GetOutput("stringToSign").(string)

		t.Logf("=== CANONICAL REQUEST ===\n%s", canonicalRequest)
		t.Logf("=== STRING TO SIGN ===\n%s", stringToSign)

		// Verify the canonical request structure matches AWS expectation
		assert.Contains(t, canonicalRequest, "POST")
		assert.Contains(t, canonicalRequest, "/075021648303/odido-demo-detelte-ops")
		assert.Contains(t, canonicalRequest, "host:sqs.eu-central-1.amazonaws.com")
		assert.Contains(t, canonicalRequest, "x-amz-content-sha256:")
		assert.Contains(t, canonicalRequest, "x-amz-date:20250827T080752Z")
		assert.Contains(t, canonicalRequest, "x-amz-security-token:")

		// Verify Content-Type is NOT in the canonical request
		assert.NotContains(t, canonicalRequest, "content-type:application/x-www-form-urlencoded")

		// The signed headers should only include AWS headers and host
		assert.Contains(t, canonicalRequest, "host;x-amz-content-sha256;x-amz-date;x-amz-security-token")
	} else {
		t.Errorf("Activity failed: %s", tc.GetOutput("errorMessage"))
	}
}
