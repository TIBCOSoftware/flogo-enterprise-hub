package vectorSearch

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"context"
	"errors"

	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
)

var logger = log.ChildLogger(log.RootLogger(), "opeanAI-vector-search-activity")

// activityMd is the metadata for the activity.
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity is an OpenAI Vector Store Search activity
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

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, err
	}

	//fileName := ctx.GetInput(iFilename).(string)
	searchString := input.SearchString

	clientCtx := context.Background()

	logger.Info("Starting vector store search with query: ", searchString)

	pages, err := a.oaiClient.VectorStores.Search(
		clientCtx,
		input.VectorStoreID,
		openai.VectorStoreSearchParams{
			Query: openai.VectorStoreSearchParamsQueryUnion{
				OfString: openai.String(searchString),
			},
			MaxNumResults: openai.Int(input.MaxNumberOfResults),
			RewriteQuery:  openai.Bool(input.RewriteQuery),
			// // TODO filters...
			RankingOptions: openai.VectorStoreSearchParamsRankingOptions{
				ScoreThreshold: openai.Float(input.ScoreThreshold),
				Ranker:         input.Ranker,
			},
		},

		//Filters: ,
		// Optional: Add filters based on your metadata schema
		// Filter: openai.VectorStoreSearchParamsFilter{
		// 	Metadata: map[string]openai.VectorStoreSearchParamsFilterValueUnion{
		// 		"category": {
		// 			OfString: openai.String("example-category"),
		// 		},
		// 	},
		// },
		// Optional: Specify which metadata fields to return in results
		// ReturnMetadata: []string{"source", "author"},
		// RankingOptions: ,

	)

	if err != nil {
		logger.Errorf("Error executing vector store search: %v\n", err)
		return false, err
	}
	out := &Output{}

	// Process results page-by-page to handle pagination and add to final output:
	for {
		for i := range pages.Data {
			out.SearchResultRows = append(out.SearchResultRows, &pages.Data[i])
		}
		logger.Info("--- Getting next page of results ---\n")

		nextPage, err := pages.GetNextPage()

		if err != nil {
			logger.Errorf("next page failed: %v", err)
			break
		}
		if nextPage == nil {
			break
		}
		// Critical fix: assign nextPage back to pages to continue pagination
		pages = nextPage
	}

	err = ctx.SetOutputObject(out)

	return true, nil
}
