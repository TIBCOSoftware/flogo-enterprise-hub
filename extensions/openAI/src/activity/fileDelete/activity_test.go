/*
 * Copyright © 2023-2026. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package fileDelete

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

func TestActivityDeletesFile(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	fileID := os.Getenv("TEST_FILE_ID")

	if fileID == "" {
		t.Skip("TEST_FILE_ID is not set; skipping integration test")
	}

	// Build the activity via New(...) so the OpenAI client gets initialized
	// with the configured base URL.
	initCtx := test.NewActivityInitContext(settingsMapFromEnv(), nil)
	act, err := New(initCtx)
	if err != nil {
		assert.FailNow(t, "failed to initialize activity", err.Error())
	}

	tc := test.NewActivityContext(act.Metadata())
	tc.SetInput("fileId", fileID)
	if v := os.Getenv("TEST_TIMEOUT_SECONDS"); v != "" {
		if n, convErr := strconv.Atoi(v); convErr == nil {
			tc.SetInput("timeoutSeconds", n)
		}
	}

	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
		return
	}

	assert.Equal(t, fileID, tc.GetOutput("id"))
	assert.Equal(t, true, tc.GetOutput("deleted"))
}

func TestActivity_MissingFileID(t *testing.T) {
	// Build via New to ensure validation runs against settings only;
	// missing fileId should fail at Eval time.
	initCtx := test.NewActivityInitContext(map[string]interface{}{
		"apiKey":      "test-key",
		"endPointURL": "https://api.openai.com/v1",
	}, nil)
	act, err := New(initCtx)
	assert.NoError(t, err)

	tc := test.NewActivityContext(act.Metadata())
	// Intentionally omit fileId

	done, err := act.Eval(tc)
	assert.False(t, done)
	assert.Error(t, err)
}

func TestActivity_Input(t *testing.T) {
	input := &Input{}

	// Test with nil values (should set defaults)
	err := input.FromMap(nil)
	assert.NoError(t, err)
	assert.Equal(t, 30, input.TimeoutSeconds)

	// Test with custom values
	inputMap := map[string]interface{}{
		"fileId":         "file-abc123",
		"timeoutSeconds": 60,
	}

	err = input.FromMap(inputMap)
	assert.NoError(t, err)
	assert.Equal(t, "file-abc123", input.FileID)
	assert.Equal(t, 60, input.TimeoutSeconds)

	// Test ToMap
	resultMap := input.ToMap()
	assert.Equal(t, "file-abc123", resultMap["fileId"])
	assert.Equal(t, 60, resultMap["timeoutSeconds"])
}

func TestActivity_Output(t *testing.T) {
	output := &Output{
		ID:      "file-abc123",
		Object:  "file",
		Deleted: true,
	}

	resultMap := output.ToMap()
	assert.Equal(t, "file-abc123", resultMap["id"])
	assert.Equal(t, "file", resultMap["object"])
	assert.Equal(t, true, resultMap["deleted"])

	// Test FromMap
	out2 := &Output{}
	inputMap := map[string]interface{}{
		"id":      "file-xyz789",
		"object":  "file",
		"deleted": false,
	}

	err := out2.FromMap(inputMap)
	assert.NoError(t, err)
	assert.Equal(t, "file-xyz789", out2.ID)
	assert.Equal(t, "file", out2.Object)
	assert.Equal(t, false, out2.Deleted)
}
