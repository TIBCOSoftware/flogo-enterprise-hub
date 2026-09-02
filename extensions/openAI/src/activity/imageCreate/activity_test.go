/*
 * Copyright © 2023 - 2026. Cloud Software Group, Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package imageCreate

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
)

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
			k, v := strings.TrimSpace(parts[0]), strings.TrimSpace(parts[1])
			if os.Getenv(k) == "" {
				os.Setenv(k, v)
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

// ----------------------------------------------------------------------------
// Cross-field validation tests (no network).
// ----------------------------------------------------------------------------

func TestValidate_NumberOfImagesRange(t *testing.T) {
	err := validateInput(&Settings{Model: "gpt-image-1", NumberOfImages: 11}, &Input{Prompt: "hi"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "between 1 and 10")
}

func TestValidate_GPTImage_AcceptsHighQuality(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", Quality: "high"}
	in := &Input{Prompt: "hi"}
	assert.NoError(t, validateInput(s, in))
}

func TestValidate_RejectsInvalidQuality(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", Quality: "hd"}
	in := &Input{Prompt: "hi"}
	err := validateInput(s, in)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "quality=low|medium|high|auto")
}

func TestValidate_TransparentBackgroundRequiresPngOrWebp(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", Background: "transparent", OutputFormat: "jpeg"}
	in := &Input{Prompt: "hi"}
	err := validateInput(s, in)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "background=transparent requires outputFormat=png|webp")
}

func TestValidate_TransparentBackgroundAllowsPng(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", Background: "transparent", OutputFormat: "png"}
	in := &Input{Prompt: "hi"}
	assert.NoError(t, validateInput(s, in))
}

func TestValidate_OutputCompressionRequiresWebpOrJpeg(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", OutputFormat: "png", OutputCompression: 50}
	in := &Input{Prompt: "hi"}
	err := validateInput(s, in)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "outputCompression only applies when outputFormat=webp|jpeg")
}

func TestValidate_OutputCompressionRangeCheck(t *testing.T) {
	s := &Settings{Model: "gpt-image-1", OutputFormat: "webp", OutputCompression: 150}
	in := &Input{Prompt: "hi"}
	err := validateInput(s, in)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "between 1 and 100")
}

func TestValidate_GPTImage1_AllowedSize(t *testing.T) {
	assert.NoError(t, validateInput(&Settings{Model: "gpt-image-1", Size: "1024x1024"}, &Input{Prompt: "hi"}))
	assert.NoError(t, validateInput(&Settings{Model: "gpt-image-1", Size: "1536x1024"}, &Input{Prompt: "hi"}))
	err := validateInput(&Settings{Model: "gpt-image-1", Size: "512x512"}, &Input{Prompt: "hi"})
	assert.Error(t, err)
}

func TestValidate_GPTImage_AutoSize(t *testing.T) {
	assert.NoError(t, validateInput(&Settings{Model: "gpt-image-1", Size: "auto"}, &Input{Prompt: "hi"}))
}

func TestValidate_GPTImage2_ArbitrarySize(t *testing.T) {
	// Valid: divisible by 16, AR within bounds.
	assert.NoError(t, validateInput(&Settings{Model: "gpt-image-2", Size: "1536x864"}, &Input{Prompt: "hi"}))
	// Invalid: not divisible by 16.
	err := validateInput(&Settings{Model: "gpt-image-2", Size: "1500x864"}, &Input{Prompt: "hi"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "divisible by 16")
	// Invalid: aspect ratio > 3:1.
	err = validateInput(&Settings{Model: "gpt-image-2", Size: "3200x800"}, &Input{Prompt: "hi"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "aspect ratio")
	// Invalid: exceeds max 3840x2160.
	err = validateInput(&Settings{Model: "gpt-image-2", Size: "4096x2160"}, &Input{Prompt: "hi"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "maximum")
}

func TestValidate_PromptLengthLimit(t *testing.T) {
	long := strings.Repeat("a", 32001)
	err := validateInput(&Settings{Model: "gpt-image-1"}, &Input{Prompt: long})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "exceeds limit 32000")
}

func TestValidate_UnknownModel(t *testing.T) {
	err := validateInput(&Settings{Model: "bogus-model"}, &Input{Prompt: "hi"})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "unknown model")
}

// DALL·E models were deprecated on May 12, 2026 and are no longer accepted.
func TestValidate_DallEModelsRejected(t *testing.T) {
	for _, m := range []string{"dall-e-2", "dall-e-3"} {
		err := validateInput(&Settings{Model: m}, &Input{Prompt: "hi"})
		assert.Error(t, err, "model %q should be rejected", m)
		assert.Contains(t, err.Error(), "unknown model")
	}
}

// ----------------------------------------------------------------------------
// Integration test (only runs with RUN_INTEGRATION=1 and credentials in .env).
// ----------------------------------------------------------------------------

func TestImageCreate_Integration(t *testing.T) {
	if os.Getenv("RUN_INTEGRATION") != "1" {
		t.Skip("integration tests disabled")
	}

	s := populateSettingsFromEnv()
	if s.ApiKey == "" || s.EndPointURL == "" {
		t.Skip("missing credentials in .env")
	}

	// Build a real activity via New() so the SDK client is wired.
	settings := map[string]interface{}{
		"apiKey":         s.ApiKey,
		"endPointURL":    s.EndPointURL,
		"model":          "gpt-image-1",
		"numberOfImages": int64(1),
		"size":           "1024x1024",
	}
	initCtx := test.NewActivityInitContext(settings, nil)
	a, err := New(initCtx)
	assert.NoError(t, err)

	tc := test.NewActivityContext(a.Metadata())
	tc.SetInput("prompt", "A cute baby sea otter")

	done, err := a.Eval(tc)
	if !done {
		fmt.Println(err)
		assert.Fail(t, "activity failed")
	}
	assert.NoError(t, err)
	assert.True(t, done)
}
