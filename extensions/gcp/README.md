# TIBCO Flogo® Extension for GCP

## Overview

TIBCO Flogo® Extension for GCP provides activity to aquire a Google-signed OpenID Connect (OIDC) ID token from a metadata server.

See https://cloud.google.com/docs/authentication/get-id-token#metadata-server

# Get ID Token Activity

Provides an activity to aquire a Google-signed OpenID Connect (OIDC) ID token from a metadata server.

## Settings

None

## Input Settings

The Input Settings tab has the following fields:

| Field	| Required	| Description |
|-------|-----------|-------------|
| url   | true      | URL of the IAM Service Account Credentials API |


## Input

None


## Output Settings
The Output Settings tab has the following field:

| Field	| Description |
|-------|-------------|
| accessToken | The granted access token |
| tokenType | The access token type i.e Bearer |
| refreshToken | Refresh token |
| expiry | Access token expiry timestamp |

## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.