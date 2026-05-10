/*
 * Copyright © 2023. Mark Mussett.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package getidtoken

import (
	"context"
	"fmt"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
	"google.golang.org/api/idtoken"
	"google.golang.org/api/option"
	"time"
)

var activityLog = log.ChildLogger(log.RootLogger(), "gcp-activity-getidtoken")

func init() {
	_ = activity.Register(&Activity{}, New)
}

var activityMd = activity.ToMetadata(&Input{}, &Output{})

func New(ctx activity.InitContext) (activity.Activity, error) {
	return &Activity{}, nil
}

type Activity struct {
}

func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}
func (a *Activity) Eval(context activity.Context) (done bool, err error) {
	activityLog.Info("Executing GetIdToken activity")

	input := &Input{}
	context.GetInputObject(input)

	//Read Inputs
	if len(input.Url) <= 0 {
		// First string is not configured
		// return error to the engine
		return false, activity.NewError("Url string is not configured", "GETIDTOKEN-4001", nil)
	}

	output := &Output{}

	token, err := getIdTokenFromMetadataServer(input.Url)
	if err != nil {
		return false, err
	}

	output.AccessToken = token.AccessToken
	output.RefreshToken = token.RefreshToken
	output.TokenType = token.TokenType
	output.Expiry = token.Expiry.Format(time.RFC3339)

	err = context.SetOutputObject(output)
	if err != nil {
		return false, err
	}
	return true, nil
}

func getIdTokenFromMetadataServer(aud string) (*oauth2.Token, error) {

	ctx := context.Background()

	activityLog.Debug("calling google.FindDefaultCredentials() function")

	credentials, err := google.FindDefaultCredentials(ctx)
	if err != nil {
		activityLog.Errorf("google.FindDefaultCredentials() function returned error, failed to generate default credentials: %w", err)
		return nil, fmt.Errorf("failed to generate default credentials: %w", err)
	}

	ts, err := idtoken.NewTokenSource(ctx, aud, option.WithCredentials(credentials))
	if err != nil {
		activityLog.Errorf("idtoken.NewTokenSource() function returned error, failed to create NewtokenSource: %w", err)
		return nil, fmt.Errorf("failed to create NewtokenSource: %w", err)
	}

	token, err := ts.Token()
	if err != nil {
		activityLog.Errorf("ts.Token() function returned error, failed to receive token: %w", err)
		return nil, fmt.Errorf("failed to receive token: %w", err)
	}

	return token, nil

}
