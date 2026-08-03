package vectorStoreCreate

/*
* Copyright © 2023 - 2026. Cloud Software Group, Inc.
* This file is subject to the license terms contained
* in the license file that is distributed with this file.
 */

import (
	"github.com/project-flogo/core/data/coerce"
)

// MetadataPair defines a key/value entry for the OpenAI metadata map.
type MetadataPair struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

// Constants for identifying settings, inputs and outputs.
const (
	sAPIKey      = "apiKey"
	sEndpointURL = "endPointURL"

	iName               = "name"
	iDescription        = "description"
	iFileIDs            = "fileIds"
	iMetadata           = "metadata"
	iExpiresAfterDays   = "expiresAfterDays"
	iMaxChunkSizeTokens = "maxChunkSizeTokens"
	iChunkOverlapTokens = "chunkOverlapTokens"
	iTimeoutSeconds     = "timeoutSeconds"

	oID                   = "id"
	oObject               = "object"
	oName                 = "name"
	oStatus               = "status"
	oCreatedAt            = "createdAt"
	oLastActiveAt         = "lastActiveAt"
	oExpiresAt            = "expiresAt"
	oUsageBytes           = "usageBytes"
	oFileCountsTotal      = "fileCountsTotal"
	oFileCountsCompleted  = "fileCountsCompleted"
	oFileCountsFailed     = "fileCountsFailed"
	oFileCountsInProgress = "fileCountsInProgress"
	oFileCountsCancelled  = "fileCountsCancelled"
	oMetadata             = "metadata"
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
	Name               string         `md:"name"`
	Description        string         `md:"description"`
	FileIDs            []string       `md:"fileIds"`
	Metadata           []MetadataPair `md:"metadata"`
	ExpiresAfterDays   int64          `md:"expiresAfterDays"`
	MaxChunkSizeTokens int64          `md:"maxChunkSizeTokens"`
	ChunkOverlapTokens int64          `md:"chunkOverlapTokens"`
	TimeoutSeconds     int            `md:"timeoutSeconds"`
}

// FromMap populates the input struct from the activity's inputs.
func (i *Input) FromMap(values map[string]interface{}) error {
	if values == nil {
		i.TimeoutSeconds = 60
		return nil
	}

	var err error

	if val, ok := values[iName]; ok && val != nil {
		i.Name, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iDescription]; ok && val != nil {
		i.Description, err = coerce.ToString(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iFileIDs]; ok && val != nil {
		arr, err := coerce.ToArray(val)
		if err != nil {
			return err
		}
		i.FileIDs = make([]string, 0, len(arr))
		for _, item := range arr {
			s, _ := coerce.ToString(item)
			if s != "" {
				i.FileIDs = append(i.FileIDs, s)
			}
		}
	}

	if val, ok := values[iMetadata]; ok && val != nil {
		arr, err := coerce.ToArray(val)
		if err != nil {
			return err
		}
		i.Metadata = make([]MetadataPair, 0, len(arr))
		for _, row := range arr {
			if m, ok := row.(map[string]interface{}); ok {
				k, _ := coerce.ToString(m["key"])
				v, _ := coerce.ToString(m["value"])
				if k != "" {
					i.Metadata = append(i.Metadata, MetadataPair{Key: k, Value: v})
				}
			}
		}
	}

	if val, ok := values[iExpiresAfterDays]; ok && val != nil {
		i.ExpiresAfterDays, err = coerce.ToInt64(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iMaxChunkSizeTokens]; ok && val != nil {
		i.MaxChunkSizeTokens, err = coerce.ToInt64(val)
		if err != nil {
			return err
		}
	}

	if val, ok := values[iChunkOverlapTokens]; ok && val != nil {
		i.ChunkOverlapTokens, err = coerce.ToInt64(val)
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
		i.TimeoutSeconds = 60
	}

	return nil
}

// ToMap converts the input struct to a map.
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		iName:               i.Name,
		iDescription:        i.Description,
		iFileIDs:            i.FileIDs,
		iMetadata:           i.Metadata,
		iExpiresAfterDays:   i.ExpiresAfterDays,
		iMaxChunkSizeTokens: i.MaxChunkSizeTokens,
		iChunkOverlapTokens: i.ChunkOverlapTokens,
		iTimeoutSeconds:     i.TimeoutSeconds,
	}
}

// Output defines what data the activity returns.
type Output struct {
	ID                   string            `md:"id"`
	Object               string            `md:"object"`
	Name                 string            `md:"name"`
	Status               string            `md:"status"`
	CreatedAt            int64             `md:"createdAt"`
	LastActiveAt         int64             `md:"lastActiveAt"`
	ExpiresAt            int64             `md:"expiresAt"`
	UsageBytes           int64             `md:"usageBytes"`
	FileCountsTotal      int64             `md:"fileCountsTotal"`
	FileCountsCompleted  int64             `md:"fileCountsCompleted"`
	FileCountsFailed     int64             `md:"fileCountsFailed"`
	FileCountsInProgress int64             `md:"fileCountsInProgress"`
	FileCountsCancelled  int64             `md:"fileCountsCancelled"`
	Metadata             map[string]string `md:"metadata"`
}

// ToMap converts the output struct to a map.
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		oID:                   o.ID,
		oObject:               o.Object,
		oName:                 o.Name,
		oStatus:               o.Status,
		oCreatedAt:            o.CreatedAt,
		oLastActiveAt:         o.LastActiveAt,
		oExpiresAt:            o.ExpiresAt,
		oUsageBytes:           o.UsageBytes,
		oFileCountsTotal:      o.FileCountsTotal,
		oFileCountsCompleted: o.FileCountsCompleted,
		oFileCountsFailed:     o.FileCountsFailed,
		oFileCountsInProgress: o.FileCountsInProgress,
		oFileCountsCancelled:  o.FileCountsCancelled,
		oMetadata:             o.Metadata,
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
	o.Name, err = coerce.ToString(values[oName])
	if err != nil {
		return err
	}
	o.Status, err = coerce.ToString(values[oStatus])
	if err != nil {
		return err
	}
	o.CreatedAt, err = coerce.ToInt64(values[oCreatedAt])
	if err != nil {
		return err
	}
	o.LastActiveAt, err = coerce.ToInt64(values[oLastActiveAt])
	if err != nil {
		return err
	}
	o.ExpiresAt, err = coerce.ToInt64(values[oExpiresAt])
	if err != nil {
		return err
	}
	o.UsageBytes, err = coerce.ToInt64(values[oUsageBytes])
	if err != nil {
		return err
	}
	o.FileCountsTotal, err = coerce.ToInt64(values[oFileCountsTotal])
	if err != nil {
		return err
	}
	o.FileCountsCompleted, err = coerce.ToInt64(values[oFileCountsCompleted])
	if err != nil {
		return err
	}
	o.FileCountsFailed, err = coerce.ToInt64(values[oFileCountsFailed])
	if err != nil {
		return err
	}
	o.FileCountsInProgress, err = coerce.ToInt64(values[oFileCountsInProgress])
	if err != nil {
		return err
	}
	o.FileCountsCancelled, err = coerce.ToInt64(values[oFileCountsCancelled])
	if err != nil {
		return err
	}

	if val, ok := values[oMetadata]; ok && val != nil {
		if m, ok := val.(map[string]string); ok {
			o.Metadata = m
		} else if m, ok := val.(map[string]interface{}); ok {
			o.Metadata = make(map[string]string, len(m))
			for k, v := range m {
				s, _ := coerce.ToString(v)
				o.Metadata[k] = s
			}
		}
	}

	return nil
}
