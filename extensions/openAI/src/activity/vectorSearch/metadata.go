package vectorSearch

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"encoding/json"

	"github.com/openai/openai-go/v3"
	"github.com/project-flogo/core/data/coerce"
)

// Constants for identifying settings and inputs
const (
	sAPIKey             = "apiKey"
	sEnpointURL         = "endPointURL"
	iSearchString       = "searchString"
	iVectorStoreID      = "vectorStoreID"
	iMaxNumberOfResults = "maxNumberOfResults"
	irewriteQuery       = "rewriteQuery"
	iScoreThreshold     = "scoreThreshold"
	iRanker             = "ranker"
	oSearchResultRows   = "searchResultRows"
)

// Settings defines configuration options for your activity
type Settings struct {
	ApiKey      string `md:"apiKey, required"`
	EndPointURL string `md:"endPointURL, required"`
}

// FromMap populates the settings struct from a map.
func (s *Settings) FromMap(values map[string]interface{}) error {
	if values == nil {
		s.ApiKey = ""
		s.EndPointURL = ""
		//
		return nil
	}

	var err error

	s.ApiKey, err = coerce.ToString(values[sAPIKey])
	if err != nil {
		return err
	}

	s.EndPointURL, err = coerce.ToString(values[sEnpointURL])
	if err != nil {
		return err
	}

	// if val, ok := values[sEnpointURL]; ok && val != nil {
	// 	s.EndPointURL, err = coerce.ToString(val)
	// 	if err != nil {
	// 		return err
	// 	}
	// }

	// if val, ok := values[sPurpose]; ok && val != nil {
	// 	s.Purpose, err = coerce.ToString(val)
	// 	if err != nil {
	// 		return err
	// 	}

	// 	if s.Purpose == "" {
	// 		s.Purpose = "assistants"
	// 	}
	// }

	// s.FileDirectory, err = coerce.ToString(values[sFileDirectory])
	// if err != nil {
	// 	return err
	// }

	return nil
}

// Input defines what data the activity receives
type Input struct {
	SearchString       string  `md:"searchString"`
	VectorStoreID      string  `md:"vectorStoreID"`
	MaxNumberOfResults int64   `md:"maxNumberOfResults"`
	RewriteQuery       bool    `md:"rewriteQuery"`
	ScoreThreshold     float64 `md:"scoreThreshold"`
	Ranker             string  `md:"ranker"`
}

// FromMap populates the struct from the activity's inputs.
func (i *Input) FromMap(values map[string]interface{}) error {

	if values == nil {
		return nil
	}

	// Todo Refactor this code to make efficient.
	var err error

	i.SearchString, err = coerce.ToString(values[iSearchString])
	if err != nil {
		return err
	}

	i.VectorStoreID, err = coerce.ToString(values[iVectorStoreID])
	if err != nil {
		return err
	}

	i.MaxNumberOfResults, err = coerce.ToInt64(values[iMaxNumberOfResults])
	if err != nil {
		return err
	}

	i.RewriteQuery, err = coerce.ToBool(values[irewriteQuery])
	if err != nil {
		return err
	}

	// Set default values if not provided
	if scoreThreshold, exists := values[iScoreThreshold]; exists && scoreThreshold != nil {
		i.ScoreThreshold, err = coerce.ToFloat64(scoreThreshold)
		if err != nil {
			return err
		}
	} else {
		i.ScoreThreshold = 0.20 // Default threshold
	}

	if ranker, exists := values[iRanker]; exists && ranker != nil {
		i.Ranker, err = coerce.ToString(ranker)
		if err != nil {
			return err
		}
	} else {
		i.Ranker = "auto" // Default ranker
	}

	// for possible future enhancements with file attributes search
	// i.FileAttributeNames, err = coerce.ToArray(values[iFileAttributeNames])
	// if err != nil {
	// 	return err
	// }

	// i.FileAttributes, err = coerce.ToObject(values[iFileAttributes])
	// if err != nil {
	// 	return err
	// }

	// var fileAttributeTemp []interface{}

	// fileAttributeTemp, err = coerce.ToArray(values[iFileAttributes])

	// logger.Info("File has attributes:" + strconv.Itoa((len(fileAttributeTemp))))

	// if err != nil {
	// 	return err
	// } else {
	// 	i.FileAttributes = make([]FileAttributeData, 0, len(fileAttributeTemp))
	// 	for _, metaRow := range fileAttributeTemp {
	// 		if m, ok := metaRow.(map[string]interface{}); ok {
	// 			key, _ := coerce.ToString(m["key"])
	// 			value, _ := coerce.ToString(m["value"])
	// 			i.FileAttributes = append(i.FileAttributes, FileAttributeData{
	// 				Key:   key,
	// 				Value: value,
	// 			})
	// 			attributekey, _ := coerce.ToString(m["key"])
	// 			logger.Info("Adding " + attributekey)
	// 		}
	// 	}
	// }

	return nil
}

// ToMap converts the struct to a map.
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		iSearchString:       i.SearchString,
		iVectorStoreID:      i.VectorStoreID,
		iMaxNumberOfResults: i.MaxNumberOfResults,
		irewriteQuery:       i.RewriteQuery,
		iScoreThreshold:     i.ScoreThreshold,
		iRanker:             i.Ranker,
	}
}

// Output defines what data the activity returns
type Output struct {
	SearchResultRows []*openai.VectorStoreSearchResponse `md:"searchResultRows"`
}

// ToMap converts the struct to a map.
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oSearchResultRows: o.SearchResultRows,
	}
}

// FromMap populates the struct from a map.
func (o *Output) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	res, err := coerce.ToArray(values[oSearchResultRows])
	if err != nil {
		return err
	}

	var vectorRows []*openai.VectorStoreSearchResponse
	vectorData, err := json.Marshal(res)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(vectorData, &vectorRows); err != nil {
		return err
	}

	o.SearchResultRows = vectorRows
	return nil
}
