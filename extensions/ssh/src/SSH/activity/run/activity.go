package run

import (
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
	"golang.org/x/crypto/ssh"
)

var activityMd = activity.ToMetadata(&Input{}, &Output{})

func init() {
	_ = activity.Register(&MyActivity{}, New)
}

// New creates a new activity
func New(ctx activity.InitContext) (activity.Activity, error) {
	return &MyActivity{logger: log.ChildLogger(ctx.Logger(), "SSH-activity-run"), activityName: "run"}, nil
}

// MyActivity is a stub for your Activity implementation
type MyActivity struct {
	logger       log.Logger
	activityName string
}

// Metadata implements activity.Activity.Metadata
func (*MyActivity) Metadata() *activity.Metadata {
	return activityMd
}

// Eval implements activity.Activity.Eval
func (activity *MyActivity) Eval(context activity.Context) (done bool, err error) {

	input := &Input{}
	output := &Output{}

	//Get Input Object
	err = context.GetInputObject(input)
	if err != nil {
		//Run the command
		return false, err
	}

	session := input.Connection.GetConnection().(*ssh.Session)

	cmd := input.Cmd

	stdOut, err := session.Output(cmd)

	if err != nil {
		return false, err
	}

	output.StdOut = string(stdOut)

	//Set output object
	err = context.SetOutputObject(output)
	if err != nil {
		return false, err
	}

	return true, nil
}
