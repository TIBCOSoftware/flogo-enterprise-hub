/*
 * Copyright © 2023-2026. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package vectorStoreList

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

// Load environment variables from .env file
func init() {
	loadEnvFile()
}

// openEnvFile opens .env from the current working directory or any ancestor
// directory. This lets a single shared .env at extensions/openAI/src/ serve
// all activity tests while a per-package .env (if present) still wins because
// it is found first.
func openEnvFile() (*os.File, error) {
	if f, err := os.Open(".env"); err == nil {
		return f, nil
	}
	dir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	for {
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
		if f, err := os.Open(filepath.Join(dir, ".env")); err == nil {
			return f, nil
		}
	}
	return nil, os.ErrNotExist
}

func loadEnvFile() {
	file, err := openEnvFile()
	if err != nil {
		fmt.Printf("No .env file found: %v\n", err)
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue // Skip empty lines and comments
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			// Only set if not already set (command line takes precedence)
			if os.Getenv(key) == "" {
				os.Setenv(key, value)
				fmt.Printf("Loaded env var: %s\n", key)
			}
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Error reading .env file: %v\n", err)
	}
}

func settingsMapFromEnv() map[string]interface{} {
	return map[string]interface{}{
		"apiKey":      os.Getenv("OPENAI_API_KEY"),
		"endPointURL": os.Getenv("OPENAI_API_ENDPOINT_URL"),
	}
}

func TestActivity_Register(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestActivityReturnsVectorStoresObject(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	// Build the activity via New(...) so the OpenAI client gets initialized
	// with the configured base URL. Constructing &Activity{} directly leaves
	// oaiClient as a zero value, which causes the SDK to report
	// "requestconfig: base url is not set" at request time.
	initCtx := test.NewActivityInitContext(settingsMapFromEnv(), nil)
	act, err := New(initCtx)
	if err != nil {
		assert.FailNow(t, "failed to initialize activity", err.Error())
	}

	tc := test.NewActivityContext(act.Metadata())
	tc.SetInput("limit", "20")
	if v := os.Getenv("TEST_TIMEOUT_SECONDS"); v != "" {
		if n, convErr := strconv.Atoi(v); convErr == nil {
			tc.SetInput("timeoutSeconds", n)
		}
	}

	done, err := act.Eval(tc)

	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}

	success := tc.GetOutput("vectorStores")
	if success != 0 {
		assert.True(t, done)
	}

}

func TestActivity_Input(t *testing.T) {
	input := &Input{}

	// Test with nil values (should set defaults)
	err := input.FromMap(nil)
	assert.NoError(t, err)
	assert.Equal(t, 20, input.Limit)
	assert.Equal(t, "desc", input.Order)
	assert.Equal(t, 30, input.TimeoutSeconds)

	// Test with custom values
	inputMap := map[string]interface{}{
		"limit":          50,
		"order":          "asc",
		"after":          "vs_abc123",
		"before":         "vs_xyz789",
		"timeoutSeconds": 60,
	}

	err = input.FromMap(inputMap)
	assert.NoError(t, err)
	assert.Equal(t, 50, input.Limit)
	assert.Equal(t, "asc", input.Order)
	assert.Equal(t, "vs_abc123", input.After)
	assert.Equal(t, "vs_xyz789", input.Before)
	assert.Equal(t, 60, input.TimeoutSeconds)

	// Test ToMap
	resultMap := input.ToMap()
	assert.Equal(t, 50, resultMap["limit"])
	assert.Equal(t, "asc", resultMap["order"])
	assert.Equal(t, "vs_abc123", resultMap["after"])
	assert.Equal(t, "vs_xyz789", resultMap["before"])
	assert.Equal(t, 60, resultMap["timeoutSeconds"])
}

func TestActivity_Output(t *testing.T) {
	output := &Output{}

	// Test ToMap
	output.HasMore = true
	output.FirstID = "vs_first"
	output.LastID = "vs_last"

	resultMap := output.ToMap()
	assert.Equal(t, true, resultMap["hasMore"])
	assert.Equal(t, "vs_first", resultMap["firstId"])
	assert.Equal(t, "vs_last", resultMap["lastId"])

	// Test FromMap
	inputMap := map[string]interface{}{
		"hasMore": false,
		"firstId": "vs_new_first",
		"lastId":  "vs_new_last",
	}

	err := output.FromMap(inputMap)
	assert.NoError(t, err)
	assert.Equal(t, false, output.HasMore)
	assert.Equal(t, "vs_new_first", output.FirstID)
	assert.Equal(t, "vs_new_last", output.LastID)
}
