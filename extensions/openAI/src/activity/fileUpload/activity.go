package fileUpload

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"context"
	"errors"
	"fmt"
	"mime"
	"os"
	"path/filepath"
	"time"

	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
	"github.com/openai/openai-go/v3/packages/param"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
)

var logger = log.ChildLogger(log.RootLogger(), "openai-file-upload")

// activityMd is the metadata for the activity.
var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})

// Metadata returns the activity's metadata.
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

func init() {
	_ = activity.Register(&Activity{}, New)
}

// Activity is a ChatGPT API activity
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
	logger.Infof("****************** Starting OpenAI File Upload Activity Eval ******************")

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, err
	}

	// Validate input parameters
	if input.FileName == "" && input.FileID == "" {
		err := errors.New("validation failed: either 'filename' or 'fileId' must be provided in input")
		logger.Error(err.Error())
		return false, err
	}

	if input.FileID != "" && input.VectorStoreID == "" {
		err := errors.New("validation failed: vectorStoreID is required when FileID is provided to associate the file with a vector store")
		logger.Error(err.Error())
		return false, err
	}

	// Create context with timeout for large file uploads
	clientCtx, cancel := context.WithTimeout(context.Background(),
		time.Duration(a.Settings.TimeoutSeconds)*time.Second)
	defer cancel()

	logger.Infof("Setting upload timeout to %d seconds for large file transfers", a.Settings.TimeoutSeconds)

	var (
		fileID       string
		fileName     string
		respObject   string
		respBytes    int64
		respCreated  int64
		respFilename string
		respPurpose  string
	)

	// Two mutually exclusive paths drive how we obtain the OpenAI file ID that
	// will be attached to the vector store:
	//
	//   1. FileID path (input.FileID is set): the caller already uploaded the
	//      file to OpenAI in a previous run (or via another activity) and just
	//      wants to register it against this vector store. We skip the upload
	//      API call entirely, so no local file is opened and the upload-related
	//      outputs (object/bytes/createdAt/filename/purpose) stay empty — only
	//      `id` is meaningful in this case.
	//
	//   2. FileName path (input.FileName is set): the file lives on the local
	//      filesystem. We open it, upload it via Files.New to get a fresh
	//      OpenAI file ID, and populate the full set of upload response
	//      outputs from the API response.
	//
	// Input validation above guarantees exactly one of these is usable.
	if input.FileID != "" {
		// Path 1: reuse an existing OpenAI file; no upload, no local file I/O.
		fileID = input.FileID
		logger.Infof("Using provided fileId '%s'; skipping file upload", fileID)
	} else {
		// Path 2: upload the local file to OpenAI, then use the returned ID.
		fileReader, err := os.Open(input.FileName)
		if err != nil {
			contextErr := fmt.Errorf("validation failed: unable to open file '%s': %w", input.FileName, err)
			logger.Error(contextErr.Error())
			return false, contextErr
		}
		defer fileReader.Close()
		fileName = filepath.Base(input.FileName)

		mimeType := mime.TypeByExtension(filepath.Ext(input.FileName))
		logger.Infof("MimeType: %s", mimeType)

		inputFile := openai.File(fileReader, fileName, mimeType)

		// Upload the file bytes to OpenAI; this is the call we skip on the FileID path.
		fileResp, err := a.oaiClient.Files.New(clientCtx, openai.FileNewParams{
			File:    inputFile,
			Purpose: openai.FilePurpose(a.Settings.Purpose),
		})
		if err != nil {
			// Check for timeout specifically
			if clientCtx.Err() == context.DeadlineExceeded {
				contextErr := fmt.Errorf("upload timeout: file '%s' upload exceeded %d seconds - consider increasing timeout for large files",
					fileName, a.Settings.TimeoutSeconds)
				logger.Error(contextErr.Error())
				return false, contextErr
			}
			contextErr := fmt.Errorf("OpenAI API error: failed to upload file '%s' to endpoint '%s' with purpose '%s': %w",
				fileName, a.Settings.EndPointURL, a.Settings.Purpose, err)
			logger.Error(contextErr.Error())
			return false, contextErr
		}

		// Capture the upload response so the activity outputs reflect the new file.
		fileID = fileResp.ID
		respObject = string(fileResp.Object)
		respBytes = fileResp.Bytes
		respCreated = fileResp.CreatedAt
		respFilename = fileResp.Filename
		respPurpose = string(fileResp.Purpose)
	}

	logger.Info("Populating custom metadata from source data...")
	customMetadata := make(map[string]openai.VectorStoreFileNewParamsAttributeUnion)
	for _, item := range input.FileAttributes {
		customMetadata[item.Key] = openai.VectorStoreFileNewParamsAttributeUnion{
			OfString: param.NewOpt(item.Value),
		}
		logger.Info("adding" + item.Key)
	}

	if input.VectorStoreID != "" {
		_, err = a.oaiClient.VectorStores.Files.New(clientCtx, input.VectorStoreID,
			openai.VectorStoreFileNewParams{
				FileID:     fileID,
				Attributes: customMetadata,
				ChunkingStrategy: openai.FileChunkingStrategyParamOfStatic(openai.StaticFileChunkingStrategyParam{
					MaxChunkSizeTokens: a.Settings.MaxChunkSizeTokens,
					ChunkOverlapTokens: a.Settings.ChunkOverlapTokens,
				}),
			},
		)

		if err != nil {
			// Check for timeout specifically
			if clientCtx.Err() == context.DeadlineExceeded {
				contextErr := fmt.Errorf("vector store timeout: adding file '%s' (ID: %s) to vector store '%s' exceeded %d seconds",
					fileName, fileID, input.VectorStoreID, a.Settings.TimeoutSeconds)
				logger.Error(contextErr.Error())
				return false, contextErr
			}
			contextErr := fmt.Errorf("vector store operation failed: unable to add file '%s' (ID: %s) to vector store '%s': %w",
				fileName, fileID, input.VectorStoreID, err)
			logger.Error(contextErr.Error())
			return false, contextErr
		}
	}

	// construct activity output
	ctx.SetOutput("id", fileID)
	ctx.SetOutput("object", respObject)
	ctx.SetOutput("bytes", respBytes)
	ctx.SetOutput("createdAt", respCreated)
	ctx.SetOutput("filename", respFilename)
	ctx.SetOutput("purpose", respPurpose)

	return true, nil
}
