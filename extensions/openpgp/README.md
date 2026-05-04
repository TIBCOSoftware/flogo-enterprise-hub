# TIBCO Flogo® Extension for OpenPGP

## Overview

TIBCO Flogo® Extension for OpenPGP provides activities to encrypt and decrypt OpenPGP messages.

# Encrypt Activity

Provides an activity to encrypt a string.

## Settings

None

## Input Settings

None

## Input

The Input tab has the following fields:

| Field     | Required | Description          |
| --------- | -------- | -------------------- |
| plaintext | true     | Plaintext to encrypt |
| publickey | true     | OpenPGP Public Key   |

## Output Settings

The Output Settings tab has the following field:

| Field      | Description                  |
| ---------- | ---------------------------- |
| ciphertext | OpenPGP encrypted ciphertext |

## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.

# Decrypt Activity

Provides an activity to decrypt a string.

## Settings

None

## Input Settings

None

## Input

The Input tab has the following fields:

| Field      | Required | Description           |
| ---------- | -------- | --------------------- |
| ciphertext | true     | Ciphertext to decrypt |
| privatekey | true     | OpenPGP Private Key   |

## Output Settings

The Output Settings tab has the following field:

| Field     | Description         |
| --------- | ------------------- |
| plaintext | Decrypted plaintext |

## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.

# Generate KeyPair Activity

Provides an activity to generate a public and private key pair that can be used to encrypt and decrypt openpgp messages.

## Settings

None

## Input Settings

None

## Input

The Input tab has the following fields:

| Field   | Required | Description       |
| ------- | -------- | ----------------- |
| name    | true     | name attribute    |
| comment | true     | comment attribute |
| email   | true     | email attribute   |

## Output Settings

The Output Settings tab has the following field:

| Field      | Description |
| ---------- | ----------- |
| publickey  | Public key  |
| privatekey | Private key |

## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.
