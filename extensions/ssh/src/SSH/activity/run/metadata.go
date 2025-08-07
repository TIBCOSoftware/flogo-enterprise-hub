package run

import (
	ssh "github.com/mmussett/extensions/SSH/connector/connection"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/support/connection"
)

// Input corresponds to activity.json inputs
type Input struct {
	Connection connection.Manager `md:"SSH Connection,required"`
	Cmd        string             `md:"cmd,required"`
}

// Output corresponds to activity.json outputs
type Output struct {
	StdOut string `md:"stdOut,required"`
}

// ToMap converts Input struct to map
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"SSH Connection": i.Connection,
		"cmd":            i.Cmd,
	}
}

// FromMap converts a map to Input struct
func (i *Input) FromMap(values map[string]interface{}) error {
	var err error
	i.Connection, err = ssh.GetSharedConfiguration(values["SSH Connection"])
	if err != nil {
		return err
	}

	i.Cmd, err = coerce.ToString(values["cmd"])
	if err != nil {
		return err
	}

	return nil
}

// ToMap converts Output struct to map
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"stdOut": o.StdOut,
	}
}

// FromMap converts a map to Output struct
func (o *Output) FromMap(values map[string]interface{}) error {
	var err error
	o.StdOut, err = coerce.ToString(values["stdOut"])
	if err != nil {
		return err
	}
	return nil
}
