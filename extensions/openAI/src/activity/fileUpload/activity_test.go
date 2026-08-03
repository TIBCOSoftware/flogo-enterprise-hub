/*
 * Copyright © 2017. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package fileUpload

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
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
				//fmt.Printf("Loaded env var: %s=%s\n", key, value)
			}
		}
	}
}

func populateSettingsFromEnv() *Settings {
	cvrtChunkOverlapTokens, _ := strconv.ParseInt(os.Getenv("TEST_CHUNK_OVERLAP_TOKENS"), 10, 64)
	cvrtMaxChunkSizeTokens, _ := strconv.ParseInt(os.Getenv("TEST_MAX_CHUNK_SIZE_TOKENS"), 10, 64)
	cvrtTimeoutSecords, _ := strconv.ParseInt(os.Getenv("TEST_TIMEOUT_SECONDS"), 10, 32)
	return &Settings{
		ApiKey:             os.Getenv("OPENAI_API_KEY"),
		EndPointURL:        os.Getenv("OPENAI_API_ENDPOINT_URL"),
		Purpose:            os.Getenv("TEST_PURPOSE"),
		ChunkOverlapTokens: cvrtChunkOverlapTokens,
		MaxChunkSizeTokens: cvrtMaxChunkSizeTokens,
		TimeoutSeconds:     int(cvrtTimeoutSecords),
	}
}

func TestRegister(t *testing.T) {

	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

func TestUploadFileFileAttributeTest(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	// Setting up activity and OpenAi Client for testing
	// Initialize settings from environment variables

	s := populateSettingsFromEnv()

	// initialize the OpenAI client
	oaiClient := openai.NewClient(
		option.WithAPIKey(s.ApiKey),
		option.WithBaseURL(s.EndPointURL),
	)
	// initializing the flogo activity
	act := &Activity{
		Settings:  s,
		oaiClient: oaiClient, // Add this field
	}

	// initialzing the test context
	tc := test.NewActivityContext(act.Metadata())

	// setting up the input parameters for the activity
	tc.SetInput("filename", "./testdata/TIB_hawk_5.2.0_vpat.pdf")
	tc.SetInput("vectorStoreID", os.Getenv("VECTOR_STORE_ID"))

	// setting up file attributes to be sent to OpenAI along with the file upload
	fileAttributes := []FileAttributeData{
		{Key: "ProductGroup",
			Value: "Integration",
		},
		{Key: "Product",
			Value: "Hawk",
		},
		{Key: "DocumentType",
			Value: "VPAT",
		},
		{Key: "ProductVersion",
			Value: "5.2.0",
		},
	}
	logger.Infof("File Attributes: %+v", fileAttributes)
	tc.SetInput("fileAttributes", fileAttributes)

	// invoke the activity's Eval method to test file upload with attributes
	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}

	metadata := tc.GetOutput("metaData")
	fmt.Printf("Metadata: %s", metadata)
}

func TestSearchDocumentsDefaultRelPath(t *testing.T) {

	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests  disabled")
	}

	s := populateSettingsFromEnv()

	// initialize the OpenAI client
	oaiClient := openai.NewClient(
		option.WithAPIKey(s.ApiKey),
		option.WithBaseURL(s.EndPointURL),
	)
	act := &Activity{
		Settings:  s,
		oaiClient: oaiClient, // Add this field
	}

	tc := test.NewActivityContext(act.Metadata())

	relPath := "./testdata/TIB_hawk_5.2.0_vpat.pdf"
	fmt.Printf("Relative path: %s\n", relPath)

	tc.SetInput("filename", relPath)
	tc.SetInput("vectorStoreID", os.Getenv("VECTOR_STORE_ID"))

	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}

	metadata := tc.GetOutput("metaData")

	fmt.Printf("Metadata: %s", metadata)
}

func TestSearchDocumentsDefaultAbsPath(t *testing.T) {

	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests  disabled")
	}

	s := populateSettingsFromEnv()

	// initialize the OpenAI client
	oaiClient := openai.NewClient(
		option.WithAPIKey(s.ApiKey),
		option.WithBaseURL(s.EndPointURL),
	)

	act := &Activity{
		Settings:  s,
		oaiClient: oaiClient, // Add this field
	}

	tc := test.NewActivityContext(act.Metadata())

	absPath, err := filepath.Abs("./testdata/TIB_hawk_5.2.0_vpat.pdf")

	if err != nil {
		panic("failed to get absolute path")
	}
	fmt.Printf("Absolute path: %s\n", absPath)
	tc.SetInput("filename", absPath)
	tc.SetInput("vectorStoreID", os.Getenv("VECTOR_STORE_ID"))

	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}

	metadata := tc.GetOutput("metaData")

	fmt.Printf("Metadata: %s", metadata)
}

func getAbs(path string, locationPath string) string {
	new_file_path := path
	new_abs_path := path
	if filepath.IsAbs(new_file_path) {
		new_abs_path = new_file_path
	} else {
		new_abs_path, _ = filepath.Abs(filepath.Join(locationPath, path))

	}
	return new_abs_path
}
