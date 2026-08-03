package vectorStoreList

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"github.com/openai/openai-go/v3"
	"github.com/project-flogo/core/data/coerce"
)

// Constants for identifying settings and inputs
const (
	sAPIKey         = "apiKey"
	sEndpointURL    = "endPointURL"
	iLimit          = "limit"
	iOrder          = "order"
	iAfter          = "after"
	iBefore         = "before"
	iTimeoutSeconds = "timeoutSeconds"
	oVectorStores   = "vectorStores"
	oHasMore        = "hasMore"
	oFirstID        = "firstId"
	oLastID         = "lastId"
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
	Order          string `md:"order"`
	After          string `md:"after"`
	Before         string `md:"before"`
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

	if val, ok := values[iBefore]; ok && val != nil {
		i.Before, err = coerce.ToString(val)
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
		iOrder:          i.Order,
		iAfter:          i.After,
		iBefore:         i.Before,
		iTimeoutSeconds: i.TimeoutSeconds,
	}
}

// Output defines what data the activity returns
type Output struct {
	VectorStores []*openai.VectorStore `md:"vectorStores"`
	HasMore      bool                  `md:"hasMore"`
	FirstID      string                `md:"firstId"`
	LastID       string                `md:"lastId"`
}

// ToMap converts the struct to a map
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oVectorStores: o.VectorStores,
		oHasMore:      o.HasMore,
		oFirstID:      o.FirstID,
		oLastID:       o.LastID,
	}
}

// FromMap populates the struct from a map
func (o *Output) FromMap(values map[string]interface{}) error {
	if values == nil {
		return nil
	}

	var err error

	if val, ok := values[oVectorStores]; ok && val != nil {
		res, err := coerce.ToArray(val)
		if err != nil {
			return err
		}

		o.VectorStores = make([]*openai.VectorStore, len(res))
		for i, item := range res {
			if vs, ok := item.(*openai.VectorStore); ok {
				o.VectorStores[i] = vs
			}
		}
	}

	if val, ok := values[oHasMore]; ok && val != nil {
		o.HasMore, err = coerce.ToBool(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[oFirstID]; ok && val != nil {
		o.FirstID, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[oLastID]; ok && val != nil {
		o.LastID, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	return nil
}
