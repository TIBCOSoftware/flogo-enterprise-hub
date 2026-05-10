package getidtoken

import (
	"github.com/project-flogo/core/data/coerce"
)

type Input struct {
	Url string `md:"url"`
}

// ToMap conversion
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"url": i.Url,
	}
}

// FromMap conversion
func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	i.Url, err = coerce.ToString(values["url"])
	if err != nil {
		return err
	}

	return nil
}

// Output struct for activity output
type Output struct {
	AccessToken  string `md:"accessToken"`
	TokenType    string `md:"tokenType"`
	RefreshToken string `md:"refreshToken"`
	Expiry       string `md:"expiry"`
}

// ToMap conversion
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"accessToken":  o.AccessToken,
		"tokenType":    o.TokenType,
		"refreshToken": o.RefreshToken,
		"expiry":       o.Expiry,
	}
}

// FromMap conversion
func (o *Output) FromMap(values map[string]interface{}) error {

	var err error
	o.AccessToken, err = coerce.ToString(values["accessToken"])
	if err != nil {
		return err
	}

	o.TokenType, err = coerce.ToString(values["tokenType"])
	if err != nil {
		return err
	}

	o.RefreshToken, err = coerce.ToString(values["refreshToken"])
	if err != nil {
		return err
	}

	o.Expiry, err = coerce.ToString(values["expiry"])
	if err != nil {
		return err
	}
	return nil
}
