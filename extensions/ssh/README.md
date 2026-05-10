# TIBCO Flogo® Extension for SSH

## Overview

TIBCO Flogo® Extension for SSH provides activity to run commands via SSH.

## Subtopics

* Creating an SSH Connection
* SSH Run


---
## Creating an SSH Connection

To use TIBCO Flogo® Connector for SSH, you must first create an SSH connection. This connection is used by all the activities in the SSH category.

<b>Procedure</b>

1. On the Connections tab, click <b>Create</b> and then select <b>SSH Connector</b>.
2. In the SSH Connector dialog, enter the connection details. For more information, see SSH Connection Details.
3. Click Save.

The SSH connection contains the parameters required to connect to the SSH server.

---
# SSH Connection Details

To establish the connection successfully, you must configure the SSH instance.

The following table gives the details of the SSH Connector dialog.


| Field | Required | Description |
|-------|----------|-------------|
| Connection Name | Yes | Unique name for the SSH connector. This name is displayed in the dropdown selection box for each activity. |
| Description | No | Brief description of the SSH connection. |
| Host | Yes | The host name or IP address of the SSH server. |
| Port | Yes | The port number of the SSH server. For SSH connections, '22' is the default, when no value is specified in this field. |
| Username | Yes | Username for connecting to your SSH server. |
| Password | Yes | Password for connecting to your SSH server. This field is visible when Public Key Authentication is set to false. |
| Public Key Authentication | Yes | Set this field to true to specify the private key, when using private key supported authentication. When you set this field to true, it displays the Private Key and Private Key Password fields. |
| Private Key | Yes	| The private key to authenticate your login. |
| Private Key Password | No | The password of the private key. |
| Strict HostKey Check | Yes | When you set this field to true, it connects only to known hosts with valid host keys that are stored in the known host file. Host keys not listed in the known host list are rejected. Strict HostKey Check verifies the incoming host key against the keys in the known hosts list. If the host key does not match an existing known host entry for the remote server, the connection is rejected. When you set this field to false, the client does not verify the server's host key entry into the known host file while establishing the connection. Note: This option can be selected with Password authentication, or Public Key Authentication methods. |
| Known Host File | Yes | Contains the public keys with the corresponding Host IP address for all hosts with which the client can communicate. This field is available only when Strict HostKey Check is set to true. Configure the path of the known host file in this field.



---

# Run Activity

Provides an activity to run a shell command.

## Settings

The Settings tab has the following fields:

| Field	| Description |
|-------|-------------|
| SSH Connection | Name of the SSH connection.


## Input Settings

The Input Settings tab has the following fields:

| Field	| Required	| Description |
|-------|-----------|-------------|
| cmd   | true      | The command to run |


## Input

None


## Output Settings
The Output Settings tab has the following field:

| Field	| Description |
|-------|-------------|
| stdOut | StdOut capture |


## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.
