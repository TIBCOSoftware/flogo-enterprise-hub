package fileList

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
	sAPIKey         = "apiKey"
	sEndpointURL    = "endPointURL"
	iLimit          = "limit"
	iPurpose        = "purpose"
	iOrder          = "order"
	iAfter          = "after"
	iTimeoutSeconds = "timeoutSeconds"
	oFiles          = "files"
)

// Settings defines configuration options for the activity
type Settings struct {
	ApiKey      string `md:"apiKey, required"`
	EndPointURL string `md:"endPointURL, required"`
}

// FromMap populates the settings struct from a map
func (s *Settings) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	s.ApiKey, err = coerce.ToString(values[sAPIKey])
	if err != nil {
		return err
	}

	s.EndPointURL, err = coerce.ToString(values[sEndpointURL])
	if err != nil {
		return err
	}

	return nil
}

// Input defines what data the activity receives
type Input struct {
	Limit          int    `md:"limit"`
	Purpose        string `md:"purpose"`
	Order          string `md:"order"`
	After          string `md:"after"`
	TimeoutSeconds int    `md:"timeoutSeconds"`
}

// FromMap populates the struct from the activity's inputs
func (i *Input) FromMap(values map[string]interface{}) error {
	if values == nil {
		// Set defaults
		i.Limit = 20
		i.Order = "desc"
		i.TimeoutSeconds = 30
		return nil
	}

	var err error

	if val, ok := values[iLimit]; ok && val != nil {
		i.Limit, err = coerce.ToInt(val)
		if err != nil {
			return err
		}
	} else {
		i.Limit = 20
	}

	if val, ok := values[iPurpose]; ok && val != nil {
		i.Purpose, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iOrder]; ok && val != nil {
		i.Order, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	} else {
		i.Order = "desc"
	}

	if val, ok := values[iAfter]; ok && val != nil {
		i.After, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iTimeoutSeconds]; ok && val != nil {
		i.TimeoutSeconds, err = coerce.ToInt(val)
		if err != nil {
			return err
		}
	} else {
		i.TimeoutSeconds = 30
	}

	return nil
}

// ToMap converts the struct to a map
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		iLimit:          i.Limit,
		iPurpose:        i.Purpose,
		iOrder:          i.Order,
		iAfter:          i.After,
		iTimeoutSeconds: i.TimeoutSeconds,
	}
}

// Output defines what data the activity returns
type Output struct {
	Files []*openai.FileObject `md:"files"`
}

// ToMap converts the struct to a map
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oFiles: o.Files,
	}
}

// FromMap populates the struct from a map
func (o *Output) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	res, err := coerce.ToArray(values[oFiles])
	if err != nil {
		return err
	}

	var files []*openai.FileObject
	fileData, err := json.Marshal(res)
	if err != nil {
		return err
	}

	if err := json.Unmarshal(fileData, &files); err != nil {
		return err
	}

	o.Files = files
	return nil
}
