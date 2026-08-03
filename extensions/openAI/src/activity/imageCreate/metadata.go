package imageCreate

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

// Constants for identifying settings, inputs, and outputs.
const (
	sAPIKey            = "apiKey"
	sEndpointURL       = "endPointURL"
	sModel             = "model"
	sNumberOfImages    = "numberOfImages"
	sSize              = "size"
	sQuality           = "quality"
	sOutputFormat      = "outputFormat"
	sBackground        = "background"
	sOutputCompression = "outputCompression"
	sModeration        = "moderation"
	sUser              = "user"

	iPrompt = "prompt"

	oCreated      = "created"
	oBackground   = "background"
	oOutputFormat = "outputFormat"
	oQuality      = "quality"
	oSize         = "size"
	oData         = "data"
	oUsage        = "usage"
)

// Settings defines configuration options for the activity.
//
// Many of these fields are conditionally valid depending on the chosen Model.
// See activity.go Eval() for the cross-field validation rules.
type Settings struct {
	ApiKey            string `md:"apiKey,required"`
	EndPointURL       string `md:"endPointURL,required"`
	Model             string `md:"model"`
	NumberOfImages    int64  `md:"numberOfImages"`
	Size              string `md:"size"`
	Quality           string `md:"quality"`
	OutputFormat      string `md:"outputFormat"`
	Background        string `md:"background"`
	OutputCompression int64  `md:"outputCompression"`
	Moderation        string `md:"moderation"`
	User              string `md:"user"`
}

// FromMap populates Settings from a map.
func (s *Settings) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	if s.ApiKey, err = coerce.ToString(values[sAPIKey]); err != nil {
		return err
	}
	if s.EndPointURL, err = coerce.ToString(values[sEndpointURL]); err != nil {
		return err
	}
	if s.Model, err = coerce.ToString(values[sModel]); err != nil {
		return err
	}
	if s.Size, err = coerce.ToString(values[sSize]); err != nil {
		return err
	}
	if s.Quality, err = coerce.ToString(values[sQuality]); err != nil {
		return err
	}
	if s.OutputFormat, err = coerce.ToString(values[sOutputFormat]); err != nil {
		return err
	}
	if s.Background, err = coerce.ToString(values[sBackground]); err != nil {
		return err
	}
	if s.Moderation, err = coerce.ToString(values[sModeration]); err != nil {
		return err
	}
	if s.User, err = coerce.ToString(values[sUser]); err != nil {
		return err
	}

	if v, ok := values[sNumberOfImages]; ok && v != nil {
		if s.NumberOfImages, err = coerce.ToInt64(v); err != nil {
			return err
		}
	}

	if v, ok := values[sOutputCompression]; ok && v != nil {
		if s.OutputCompression, err = coerce.ToInt64(v); err != nil {
			return err
		}
	}

	return nil
}

// Input defines what data the activity receives.
type Input struct {
	Prompt string `md:"prompt,required"`
}

// FromMap populates Input from a map.
func (i *Input) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	if i.Prompt, err = coerce.ToString(values[iPrompt]); err != nil {
		return err
	}

	return nil
}

// ToMap converts Input to a map.
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		iPrompt: i.Prompt,
	}
}

// Output defines what data the activity returns.
type Output struct {
	Created      int64                  `md:"created"`
	Background   string                 `md:"background"`
	OutputFormat string                 `md:"outputFormat"`
	Quality      string                 `md:"quality"`
	Size         string                 `md:"size"`
	Data         []*openai.Image        `md:"data"`
	Usage        map[string]interface{} `md:"usage"`
}

// ToMap converts Output to a map.
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oCreated:      o.Created,
		oBackground:   o.Background,
		oOutputFormat: o.OutputFormat,
		oQuality:      o.Quality,
		oSize:         o.Size,
		oData:         o.Data,
		oUsage:        o.Usage,
	}
}

// FromMap populates Output from a map.
func (o *Output) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	if o.Created, err = coerce.ToInt64(values[oCreated]); err != nil {
		return err
	}
	if o.Background, err = coerce.ToString(values[oBackground]); err != nil {
		return err
	}
	if o.OutputFormat, err = coerce.ToString(values[oOutputFormat]); err != nil {
		return err
	}
	if o.Quality, err = coerce.ToString(values[oQuality]); err != nil {
		return err
	}
	if o.Size, err = coerce.ToString(values[oSize]); err != nil {
		return err
	}
	if o.Usage, err = coerce.ToObject(values[oUsage]); err != nil {
		return err
	}

	res, err := coerce.ToArray(values[oData])
	if err != nil {
		return err
	}
	dataBytes, err := json.Marshal(res)
	if err != nil {
		return err
	}
	var images []*openai.Image
	if err := json.Unmarshal(dataBytes, &images); err != nil {
		return err
	}
	o.Data = images

	return nil
}
