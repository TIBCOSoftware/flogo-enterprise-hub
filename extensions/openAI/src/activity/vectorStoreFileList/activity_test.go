package vectorStoreFileList

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
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
				// Print only the key name to avoid leaking secrets to logs
				fmt.Printf("Loaded env var: %s\n", key)
			}
		}
	}
}

func TestRegister(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestActivity_Settings(t *testing.T) {
	s := &Settings{}

	// Test default values
	err := s.FromMap(nil)
	require.NoError(t, err)

	// Test with values
	values := map[string]interface{}{
		"apiKey":      "test-key",
		"endPointURL": "https://api.openai.com/v1",
	}

	err = s.FromMap(values)
	require.NoError(t, err)
	assert.Equal(t, "test-key", s.ApiKey)
	assert.Equal(t, "https://api.openai.com/v1", s.EndPointURL)
}

func TestActivity_Input(t *testing.T) {
	i := &Input{}

	// Test default values
	err := i.FromMap(nil)
	require.NoError(t, err)
	assert.Equal(t, 20, i.Limit)
	assert.Equal(t, "desc", i.Order)
	assert.Equal(t, 30, i.TimeoutSeconds)

	values := map[string]interface{}{
		"vectorStoreID":  "vs_123",
		"limit":          10,
		"filter":         "completed",
		"order":          "asc",
		"timeoutSeconds": 60,
	}

	err = i.FromMap(values)
	require.NoError(t, err)
	assert.Equal(t, "vs_123", i.VectorStoreID)
	assert.Equal(t, 10, i.Limit)
	assert.Equal(t, "completed", i.Filter)
	assert.Equal(t, "asc", i.Order)
	assert.Equal(t, 60, i.TimeoutSeconds)

	toMap := i.ToMap()
	assert.Equal(t, "vs_123", toMap["vectorStoreID"])
	assert.Equal(t, 10, toMap["limit"])
	assert.Equal(t, "completed", toMap["filter"])
}

func TestActivity_New_ValidationErrors(t *testing.T) {
	// Test missing API key
	ctx := test.NewActivityInitContext(map[string]interface{}{
		"endPointURL": "https://api.openai.com/v1",
	}, nil)

	_, err := New(ctx)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "API key is required")

	// Test missing endpoint URL
	ctx = test.NewActivityInitContext(map[string]interface{}{
		"apiKey": "test-key",
	}, nil)

	_, err = New(ctx)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "endpoint URL is required")
}

func TestActivity_Eval_ValidationError(t *testing.T) {
	// Create activity with valid settings
	ctx := test.NewActivityInitContext(map[string]interface{}{
		"apiKey":      "test-key",
		"endPointURL": "https://api.openai.com/v1",
	}, nil)

	act, err := New(ctx)
	require.NoError(t, err)

	// Test with missing vector store ID
	evalCtx := test.NewActivityContext(act.Metadata())

	done, err := act.Eval(evalCtx)
	assert.False(t, done)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "validation failed: vector store ID is required but not provided in input")
}

// Integration test - only runs when RUN_INTEGRATION=1
func TestActivity_Integration(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("Skipping integration test. Set RUN_INTEGRATION=1 to run.")
	}

	apiKey := os.Getenv("OPENAI_API_KEY")
	endpointURL := os.Getenv("OPENAI_API_ENDPOINT_URL")
	vectorStoreID := os.Getenv("VECTOR_STORE_ID")

	if apiKey == "" {
		t.Skip("Skipping integration test: OPENAI_API_KEY not set")
	}
	if endpointURL == "" {
		t.Skip("Skipping integration test: OPENAI_API_ENDPOINT_URL not set")
	}
	if vectorStoreID == "" {
		t.Skip("Skipping integration test: VECTOR_STORE_ID not set")
	}

	// Create activity
	ctx := test.NewActivityInitContext(map[string]interface{}{
		"apiKey":      apiKey,
		"endPointURL": endpointURL,
	}, nil)

	act, err := New(ctx)
	require.NoError(t, err)

	// Execute activity
	evalCtx := test.NewActivityContext(act.Metadata())
	evalCtx.SetInput("vectorStoreID", vectorStoreID)
	evalCtx.SetInput("limit", 5)
	evalCtx.SetInput("order", "desc")
	evalCtx.SetInput("timeoutSeconds", 30)

	done, err := act.Eval(evalCtx)
	assert.True(t, done)
	require.NoError(t, err)

	// Check output
	files := evalCtx.GetOutput("files")
	require.NotNil(t, files)
	t.Logf("Retrieved files: %+v", files)
}
