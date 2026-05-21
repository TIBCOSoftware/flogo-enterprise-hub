package transformxml

import (
	"fmt"

	"github.com/davewins/xslt"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/metadata"
	"github.com/project-flogo/core/support/log"
)

func init() {

	//err := activity.Register(&Activity{})
	//err := activity.Register(&Activity{}, New) to create instances using factory method 'New'

	err := activity.Register(&Activity{}, New)
	if err != nil {
		log.RootLogger().Error(err)
	}
}

var activityMd = activity.ToMetadata(&Settings{}, &Input{}, &Output{})
var activityLog = log.ChildLogger(log.RootLogger(), "XSLT-Transformer-Transform XML")

// New optional factory method, should be used if one activity instance per configuration is desired
func New(ctx activity.InitContext) (activity.Activity, error) {

	s := &Settings{}
	err := metadata.MapToStruct(ctx.Settings(), s, true)
	if err != nil {
		return nil, err
	}

	act := &Activity{logger: log.ChildLogger(ctx.Logger(), "XSLT-Transformer-Transform XML"), activityName: "Transform XML"}

	return act, nil
}

// Activity is an sample Activity that can be used as a base to create a custom activity
type Activity struct {
	logger       log.Logger
	activityName string
}

// Metadata returns the activity's metadata
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

// Cleanup method
func (a *Activity) Cleanup() error {

	return nil
}

// Eval implements api.Activity.Eval - Logs the Message
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {

	activityLog.Infof("Executing Activity [%s]", ctx.Name())

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, fmt.Errorf("Error while getting input object: %s", err.Error())
	}
	ctx.Logger().Infof("Input XSLT (%d bytes): %s", len(input.Xslt), string(input.Xslt))
	ctx.Logger().Infof("Input XML (%d bytes): %s", len(input.Xml), string(input.Xml))
	ctx.Logger().Infof("Input Params: %v", input.Params)

	processor, err := xslt.New(input.Xslt)
	if err != nil {
		return false, fmt.Errorf("XSLT stylesheet compilation failed: %s", err.Error())
	}

	params := make(map[string]interface{}, len(input.Params))
	for k, v := range input.Params {
		if v != nil {
			params[k] = v
		}
	}

	output := &Output{}

	output.Transformedxml, err = processor.TransformWithParams(input.Xml, params)
	if err != nil {
		return false, fmt.Errorf("XSLT transformation failed: %s", err.Error())
	}

	err = ctx.SetOutputObject(output)
	if err != nil {
		return true, err
	}

	activityLog.Infof("Execution of Activity [%s] completed", ctx.Name())
	return true, nil
}
