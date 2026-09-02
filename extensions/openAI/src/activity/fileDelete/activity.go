package fileDelete

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
)

var logger = log.ChildLogger(log.RootLogger(), "openai-file-delete")

// activityMd is the metadata for the activity.
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity is an OpenAI File Delete activity.
type Activity struct {
	Settings  *Settings
	oaiClient openai.Client
}

// New creates a new instance of the Activity.
func New(ctx activity.InitContext) (activity.Activity, error) {
	s := &Settings{}
	err := s.FromMap(ctx.Settings())
	if err != nil {
		return nil, err
	}

	// Validate required settings during initialization
	if s.ApiKey == "" {
		return nil, errors.New("validation failed: OpenAI API key is required but not provided in activity settings")
	}

	if s.EndPointURL == "" {
		return nil, errors.New("validation failed: OpenAI endpoint URL is required but not provided in activity settings")
	}

	// Create OpenAI client once during initialization
	oaiClient := openai.NewClient(
		option.WithAPIKey(s.ApiKey),
		option.WithBaseURL(s.EndPointURL),
	)

	logger.Infof("OpenAI client initialized for endpoint: %s", s.EndPointURL)

	return &Activity{
		Settings:  s,
		oaiClient: oaiClient,
	}, nil
}

// Eval executes the activity.
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger.Infof("****************** Starting OpenAI File Delete Activity Eval ******************")

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, err
	}

	// Validate required input
	if input.FileID == "" {
		err := errors.New("validation failed: fileId is required but not provided in input")
		logger.Error(err.Error())
		return false, err
	}

	// Create context with timeout
	clientCtx, cancel := context.WithTimeout(context.Background(),
		time.Duration(input.TimeoutSeconds)*time.Second)
	defer cancel()

	logger.Infof("Setting request timeout to %d seconds", input.TimeoutSeconds)
	logger.Infof("Deleting file with id '%s'", input.FileID)

	// Call the OpenAI API
	deleted, err := a.oaiClient.Files.Delete(clientCtx, input.FileID)
	if err != nil {
		// Check for timeout specifically
		if clientCtx.Err() == context.DeadlineExceeded {
			contextErr := fmt.Errorf("request timeout: deleting file '%s' exceeded %d seconds",
				input.FileID, input.TimeoutSeconds)
			logger.Error(contextErr.Error())
			return false, contextErr
		}
		contextErr := fmt.Errorf("OpenAI API error: failed to delete file '%s' at endpoint '%s': %w",
			input.FileID, a.Settings.EndPointURL, err)
		logger.Error(contextErr.Error())
		return false, contextErr
	}

	out := &Output{
		ID:      deleted.ID,
		Object:  string(deleted.Object),
		Deleted: deleted.Deleted,
	}

	logger.Infof("Successfully deleted file with id '%s' (deleted=%t)", out.ID, out.Deleted)

	if err = ctx.SetOutputObject(out); err != nil {
		logger.Errorf("Failed to set output object: %v", err)
		return false, err
	}

	return true, nil
}
