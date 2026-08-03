package vectorStoreList

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

var logger = log.ChildLogger(log.RootLogger(), "openai-vector-store-list")

// activityMd is the metadata for the activity.
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity is a OpenAI Vector Store List activity
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

func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger.Infof("****************** Starting OpenAI Vector Store List Activity Eval ******************")

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

	// Prepare list parameters
	listParams := openai.VectorStoreListParams{
		Limit: openai.Int(int64(input.Limit)),
		Order: openai.VectorStoreListParamsOrder(input.Order),
	}

	// Add pagination cursors if specified
	if input.After != "" {
		listParams.After = openai.String(input.After)
		logger.Infof("Using 'after' cursor: %s", input.After)
	}

	if input.Before != "" {
		listParams.Before = openai.String(input.Before)
		logger.Infof("Using 'before' cursor: %s", input.Before)
	}

	logger.Infof("Listing vector stores with limit: %d, order: %s", input.Limit, input.Order)

	// Call the OpenAI API
	pages, err := a.oaiClient.VectorStores.List(clientCtx, listParams)
	if err != nil {
		// Check for timeout specifically
		if clientCtx.Err() == context.DeadlineExceeded {
			contextErr := fmt.Errorf("request timeout: listing vector stores exceeded %d seconds",
				input.TimeoutSeconds)
			logger.Error(contextErr.Error())
			return false, contextErr
		}
		contextErr := fmt.Errorf("OpenAI API error: failed to list vector stores at endpoint '%s': %w",
			a.Settings.EndPointURL, err)
		logger.Error(contextErr.Error())
		return false, contextErr
	}

	out := &Output{}

	// Process results page-by-page to handle pagination and add to final output
	vectorStoreCount := 0
	var firstVS, lastVS *openai.VectorStore

	for {
		for i := range pages.Data {
			vs := &pages.Data[i]
			out.VectorStores = append(out.VectorStores, vs)
			if vectorStoreCount == 0 {
				firstVS = vs
			}
			if i == len(pages.Data)-1 {
				lastVS = vs
			}
			vectorStoreCount++
		}

		logger.Infof("Retrieved %d vector stores from current page", len(pages.Data))

		nextPage, err := pages.GetNextPage()
		if err != nil {
			logger.Errorf("Error getting next page: %v", err)
			break
		}
		if nextPage == nil {
			logger.Info("No more pages to retrieve")
			out.HasMore = false
			break
		}
		pages = nextPage
		out.HasMore = true
	}

	// Set pagination metadata
	if firstVS != nil {
		out.FirstID = firstVS.ID
	}
	if lastVS != nil {
		out.LastID = lastVS.ID
	}

	logger.Infof("Successfully retrieved %d vector stores", vectorStoreCount)

	err = ctx.SetOutputObject(out)
	if err != nil {
		logger.Errorf("Failed to set output object: %v", err)
		return false, err
	}

	return true, nil
}
