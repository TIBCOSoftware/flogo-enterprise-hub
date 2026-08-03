/*
 * Copyright © 2023-2026. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package vectorStoreCreate

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
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 {
			key := strings.TrimSpace(parts[0])
			value := strings.TrimSpace(parts[1])
			if os.Getenv(key) == "" {
				os.Setenv(key, value)
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

func TestActivity_Input_Defaults(t *testing.T) {
	input := &Input{}
	err := input.FromMap(nil)
	assert.NoError(t, err)
	assert.Equal(t, 60, input.TimeoutSeconds)
}

func TestActivity_Input_Custom(t *testing.T) {
	input := &Input{}
	inMap := map[string]interface{}{
		"name":               "my-store",
		"description":        "test store",
		"fileIds":            []interface{}{"file_abc", "file_def"},
		"metadata":           []interface{}{map[string]interface{}{"key": "team", "value": "rag"}},
		"expiresAfterDays":   30,
		"maxChunkSizeTokens": 800,
		"chunkOverlapTokens": 400,
		"timeoutSeconds":     45,
	}
	err := input.FromMap(inMap)
	assert.NoError(t, err)
	assert.Equal(t, "my-store", input.Name)
	assert.Equal(t, "test store", input.Description)
	assert.Equal(t, []string{"file_abc", "file_def"}, input.FileIDs)
	assert.Equal(t, 1, len(input.Metadata))
	assert.Equal(t, "team", input.Metadata[0].Key)
	assert.Equal(t, "rag", input.Metadata[0].Value)
	assert.Equal(t, int64(30), input.ExpiresAfterDays)
	assert.Equal(t, int64(800), input.MaxChunkSizeTokens)
	assert.Equal(t, int64(400), input.ChunkOverlapTokens)
	assert.Equal(t, 45, input.TimeoutSeconds)

	m := input.ToMap()
	assert.Equal(t, "my-store", m["name"])
	assert.Equal(t, 45, m["timeoutSeconds"])
}

func TestActivity_Output(t *testing.T) {
	output := &Output{
		ID:     "vs_123",
		Status: "in_progress",
		Name:   "store",
	}

	m := output.ToMap()
	assert.Equal(t, "vs_123", m["id"])
	assert.Equal(t, "in_progress", m["status"])

	other := &Output{}
	err := other.FromMap(m)
	assert.NoError(t, err)
	assert.Equal(t, "vs_123", other.ID)
	assert.Equal(t, "store", other.Name)
}

func TestActivity_CreateVectorStore_Integration(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	initCtx := test.NewActivityInitContext(settingsMapFromEnv(), nil)
	act, err := New(initCtx)
	if err != nil {
		assert.FailNow(t, "failed to initialize activity", err.Error())
	}

	tc := test.NewActivityContext(act.Metadata())
	name := os.Getenv("TEST_VECTOR_STORE_NAME")
	if name == "" {
		name = "flogo-test-store"
	}
	tc.SetInput("name", name)
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

	id := tc.GetOutput("id")
	fmt.Printf("Created vector store id: %v\n", id)
	assert.NotEmpty(t, id)
}
