package vectorStoreDelete

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"github.com/project-flogo/core/data/coerce"
)

// Constants for identifying settings, inputs and outputs.
const (
	sAPIKey      = "apiKey"
	sEndpointURL = "endPointURL"

	iVectorStoreID  = "vectorStoreId"
	iTimeoutSeconds = "timeoutSeconds"

	oID      = "id"
	oObject  = "object"
	oDeleted = "deleted"
)

// Settings defines configuration options for the activity.
type Settings struct {
	ApiKey      string `md:"apiKey, required"`
	EndPointURL string `md:"endPointURL, required"`
}

// FromMap populates the settings struct from a map.
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

// Input defines what data the activity receives.
type Input struct {
	VectorStoreID  string `md:"vectorStoreId,required"`
	TimeoutSeconds int    `md:"timeoutSeconds"`
}

// FromMap populates the input struct from the activity's inputs.
func (i *Input) FromMap(values map[string]interface{}) error {
	if values == nil {
		i.TimeoutSeconds = 30
		return nil
	}

	var err error

	if val, ok := values[iVectorStoreID]; ok && val != nil {
		i.VectorStoreID, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iTimeoutSeconds]; ok && val != nil {
		i.TimeoutSeconds, err = coerce.ToInt(val)
		if err != nil {
			return err
		}
	}
	if i.TimeoutSeconds <= 0 {
		i.TimeoutSeconds = 30
	}

	return nil
}

// ToMap converts the input struct to a map.
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		iVectorStoreID:  i.VectorStoreID,
		iTimeoutSeconds: i.TimeoutSeconds,
	}
}

// Output defines what data the activity returns.
type Output struct {
	ID      string `md:"id"`
	Object  string `md:"object"`
	Deleted bool   `md:"deleted"`
}

// ToMap converts the output struct to a map.
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oID:      o.ID,
		oObject:  o.Object,
		oDeleted: o.Deleted,
	}
}

// FromMap populates the output struct from a map.
func (o *Output) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	o.ID, err = coerce.ToString(values[oID])
	if err != nil {
		return err
	}
	o.Object, err = coerce.ToString(values[oObject])
	if err != nil {
		return err
	}
	o.Deleted, err = coerce.ToBool(values[oDeleted])
	if err != nil {
		return err
	}

	return nil
}
