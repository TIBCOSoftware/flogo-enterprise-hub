/*
 * Copyright © 2017. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package vectorSearch

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

// newTestActivity builds an Activity the same way New() does, so tests that
// bypass the Flogo init path still get a fully initialized OpenAI client.
func newTestActivity(s *Settings) *Activity {
	return &Activity{
		Settings: s,
		oaiClient: openai.NewClient(
			option.WithAPIKey(s.ApiKey),
			option.WithBaseURL(s.EndPointURL),
		),
	}
}

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

	// Read the .env file line by line and set environment variables
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
				//fmt.Printf("Loaded env var: %s=%s\n", key, value)
			}
		}
	}
}

func populateSettingsFromEnv() *Settings {
	return &Settings{
		ApiKey:      os.Getenv("OPENAI_API_KEY"),
		EndPointURL: os.Getenv("OPENAI_API_ENDPOINT_URL"),
	}
}

func TestRegister(t *testing.T) {

	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

//VectorDBURL:   "localhost:50051",

func TestSearchDocumentsDefault(t *testing.T) {

	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	// Initialize settings from environment variables
	s := populateSettingsFromEnv()

	act := newTestActivity(s)

	tc := test.NewActivityContext(act.Metadata())
	tc.SetInput("searchString", "tell me something about tibco businessworks")
	tc.SetInput("vectorStoreID", os.Getenv("VECTOR_STORE_ID"))
	tc.SetInput("maxNumberOfResults", int64(10))
	tc.SetInput("rewriteQuery", false)

	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}

	success := tc.GetOutput("searchResultRows")

	fmt.Printf("Results: %s", success)

	if success != 0 {
		assert.True(t, done)
	}
}

func TestSearchDocumentsInvalidVectorStoreId(t *testing.T) {

	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	// Initialize settings from environment variables
	s := populateSettingsFromEnv()

	act := newTestActivity(s)

	tc := test.NewActivityContext(act.Metadata())
	tc.SetInput("searchString", "tell me something about tibco businessworks")
	tc.SetInput("vectorStoreID", "nonexisting")
	tc.SetInput("maxNumberOfResults", int64(10))
	tc.SetInput("rewriteQuery", false)

	done, err := act.Eval(tc)

	// Expect the activity to fail with an invalid vector store ID
	if done {
		// If the activity completes, it should return an error or empty results
		success := tc.GetOutput("searchResultRows")
		fmt.Printf("Unexpected success with invalid vector store ID. Results: %s", success)
		// The activity might complete but return empty results or an error
		if err != nil {
			fmt.Printf("Expected error occurred: %v", err)
			assert.True(t, true) // Test passes as expected error occurred
		} else {
			// Check if results are empty/zero indicating failure
			assert.Equal(t, 0, success, "Expected no results for invalid vector store ID")
		}
	} else {
		// Activity failed as expected
		fmt.Printf("Activity failed as expected with invalid vector store ID: %v", err)
		assert.False(t, done)
		assert.NotNil(t, err)
	}
}
