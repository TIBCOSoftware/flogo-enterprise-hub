package awssignaturev4

import (
	"github.com/project-flogo/core/data/coerce"
)

// Settings struct for activity settings (empty since all inputs are now mappable)
type Settings struct {
}

// Input struct for activity input
type Input struct {
	AccessKeyID     string                 `md:"accessKeyId"`
	SecretAccessKey string                 `md:"secretAccessKey"`
	Region          string                 `md:"region"`
	Service         string                 `md:"service"`
	SessionToken    string                 `md:"sessionToken"`
	HTTPMethod      string                 `md:"httpMethod"`
	URL             string                 `md:"url"`
	Payload         string                 `md:"payload"`
	Headers         map[string]interface{} `md:"headers"`
	Timestamp       string                 `md:"timestamp"`
}

// ToMap conversion
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"accessKeyId":     i.AccessKeyID,
		"secretAccessKey": i.SecretAccessKey,
		"region":          i.Region,
		"service":         i.Service,
		"sessionToken":    i.SessionToken,
		"httpMethod":      i.HTTPMethod,
		"url":             i.URL,
		"payload":         i.Payload,
		"headers":         i.Headers,
		"timestamp":       i.Timestamp,
	}
}

// FromMap conversion
func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	i.AccessKeyID, err = coerce.ToString(values["accessKeyId"])
	if err != nil {
		return err
	}

	i.SecretAccessKey, err = coerce.ToString(values["secretAccessKey"])
	if err != nil {
		return err
	}

	i.Region, err = coerce.ToString(values["region"])
	if err != nil {
		return err
	}

	i.Service, err = coerce.ToString(values["service"])
	if err != nil {
		return err
	}

	i.SessionToken, err = coerce.ToString(values["sessionToken"])
	if err != nil {
		return err
	}

	i.HTTPMethod, err = coerce.ToString(values["httpMethod"])
	if err != nil {
		return err
	}

	i.URL, err = coerce.ToString(values["url"])
	if err != nil {
		return err
	}

	i.Payload, err = coerce.ToString(values["payload"])
	if err != nil {
		return err
	}

	i.Headers, err = coerce.ToObject(values["headers"])
	if err != nil {
		return err
	}

	i.Timestamp, err = coerce.ToString(values["timestamp"])
	if err != nil {
		return err
	}

	return nil
}

// Output struct for activity output
type Output struct {
	Success             bool                   `md:"success"`
	AuthorizationHeader string                 `md:"authorizationHeader"`
	XAmzDate            string                 `md:"xAmzDate"`
	XAmzContentSha256   string                 `md:"xAmzContentSha256"`
	XAmzSecurityToken   string                 `md:"xAmzSecurityToken"`
	AllHeaders          map[string]interface{} `md:"allHeaders"`
	CanonicalRequest    string                 `md:"canonicalRequest"`
	StringToSign        string                 `md:"stringToSign"`
	ErrorCode           string                 `md:"errorCode"`
	ErrorMessage        string                 `md:"errorMessage"`
	ErrorDetails        map[string]interface{} `md:"errorDetails"`
}

// ToMap conversion
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"success":             o.Success,
		"authorizationHeader": o.AuthorizationHeader,
		"xAmzDate":            o.XAmzDate,
		"xAmzContentSha256":   o.XAmzContentSha256,
		"xAmzSecurityToken":   o.XAmzSecurityToken,
		"allHeaders":          o.AllHeaders,
		"canonicalRequest":    o.CanonicalRequest,
		"stringToSign":        o.StringToSign,
		"errorCode":           o.ErrorCode,
		"errorMessage":        o.ErrorMessage,
		"errorDetails":        o.ErrorDetails,
	}
}

// FromMap conversion
func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	o.Success, err = coerce.ToBool(values["success"])
	if err != nil {
		return err
	}

	o.AuthorizationHeader, err = coerce.ToString(values["authorizationHeader"])
	if err != nil {
		return err
	}

	o.XAmzDate, err = coerce.ToString(values["xAmzDate"])
	if err != nil {
		return err
	}

	o.XAmzContentSha256, err = coerce.ToString(values["xAmzContentSha256"])
	if err != nil {
		return err
	}

	o.XAmzSecurityToken, err = coerce.ToString(values["xAmzSecurityToken"])
	if err != nil {
		return err
	}

	o.AllHeaders, err = coerce.ToObject(values["allHeaders"])
	if err != nil {
		return err
	}

	o.CanonicalRequest, err = coerce.ToString(values["canonicalRequest"])
	if err != nil {
		return err
	}

	o.StringToSign, err = coerce.ToString(values["stringToSign"])
	if err != nil {
		return err
	}

	o.ErrorCode, err = coerce.ToString(values["errorCode"])
	if err != nil {
		return err
	}

	o.ErrorMessage, err = coerce.ToString(values["errorMessage"])
	if err != nil {
		return err
	}

	o.ErrorDetails, err = coerce.ToObject(values["errorDetails"])
	if err != nil {
		return err
	}

	return nil
}
