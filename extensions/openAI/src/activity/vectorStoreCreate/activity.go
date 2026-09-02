package vectorStoreCreate

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
	"github.com/openai/openai-go/v3/packages/param"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
)

var logger = log.ChildLogger(log.RootLogger(), "openai-vector-store-create")

// activityMd is the metadata for the activity.
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity is an OpenAI Vector Store Create activity.
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
	logger.Infof("****************** Starting OpenAI Vector Store Create Activity Eval ******************")

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, err
	}

	// Create context with timeout
	clientCtx, cancel := context.WithTimeout(context.Background(),
		time.Duration(input.TimeoutSeconds)*time.Second)
	defer cancel()

	logger.Infof("Setting request timeout to %d seconds", input.TimeoutSeconds)

	// Build request parameters
	params := openai.VectorStoreNewParams{}

	if input.Name != "" {
		params.Name = param.NewOpt(input.Name)
		logger.Infof("Vector store name: %s", input.Name)
	}

	if input.Description != "" {
		params.Description = param.NewOpt(input.Description)
	}

	if len(input.FileIDs) > 0 {
		params.FileIDs = input.FileIDs
		logger.Infof("Attaching %d file id(s) to the new vector store", len(input.FileIDs))
	}

	if len(input.Metadata) > 0 {
		md := make(map[string]string, len(input.Metadata))
		for _, kv := range input.Metadata {
			md[kv.Key] = kv.Value
		}
		params.Metadata = md
		logger.Infof("Attaching %d metadata entries", len(md))
	}

	if input.ExpiresAfterDays > 0 {
		params.ExpiresAfter = openai.VectorStoreNewParamsExpiresAfter{
			Days: input.ExpiresAfterDays,
		}
		logger.Infof("Vector store will expire %d day(s) after last activity", input.ExpiresAfterDays)
	}

	// Chunking strategy is only meaningful when files are provided.
	if len(input.FileIDs) > 0 && (input.MaxChunkSizeTokens > 0 || input.ChunkOverlapTokens > 0) {
		params.ChunkingStrategy = openai.FileChunkingStrategyParamOfStatic(openai.StaticFileChunkingStrategyParam{
			MaxChunkSizeTokens: input.MaxChunkSizeTokens,
			ChunkOverlapTokens: input.ChunkOverlapTokens,
		})
		logger.Infof("Using static chunking strategy (maxChunkSizeTokens=%d, chunkOverlapTokens=%d)",
			input.MaxChunkSizeTokens, input.ChunkOverlapTokens)
	}

	// Call the OpenAI API
	vs, err := a.oaiClient.VectorStores.New(clientCtx, params)
	if err != nil {
		if clientCtx.Err() == context.DeadlineExceeded {
			contextErr := fmt.Errorf("request timeout: creating vector store exceeded %d seconds",
				input.TimeoutSeconds)
			logger.Error(contextErr.Error())
			return false, contextErr
		}
		contextErr := fmt.Errorf("OpenAI API error: failed to create vector store at endpoint '%s': %w",
			a.Settings.EndPointURL, err)
		logger.Error(contextErr.Error())
		return false, contextErr
	}

	out := &Output{
		ID:                   vs.ID,
		Object:               string(vs.Object),
		Name:                 vs.Name,
		Status:               string(vs.Status),
		CreatedAt:            vs.CreatedAt,
		LastActiveAt:         vs.LastActiveAt,
		ExpiresAt:            vs.ExpiresAt,
		UsageBytes:           vs.UsageBytes,
		FileCountsTotal:      vs.FileCounts.Total,
		FileCountsCompleted:  vs.FileCounts.Completed,
		FileCountsFailed:     vs.FileCounts.Failed,
		FileCountsInProgress: vs.FileCounts.InProgress,
		FileCountsCancelled:  vs.FileCounts.Cancelled,
		Metadata:             map[string]string(vs.Metadata),
	}

	logger.Infof("Successfully created vector store with id '%s' (status=%s)", out.ID, out.Status)

	if err = ctx.SetOutputObject(out); err != nil {
		logger.Errorf("Failed to set output object: %v", err)
		return false, err
	}

	return true, nil
}
