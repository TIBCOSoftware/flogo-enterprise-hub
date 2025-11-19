package transform

import (
	"fmt"

	"github.com/jbowtie/gokogiri"
	"github.com/jbowtie/ratago/xslt"

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
var activityLog = log.ChildLogger(log.RootLogger(), "XSLT-transform")

// New optional factory method, should be used if one activity instance per configuration is desired
func New(ctx activity.InitContext) (activity.Activity, error) {

	s := &Settings{}

	err := metadata.MapToStruct(ctx.Settings(), s, true)
	if err != nil {
		return nil, err
	}

	act := &Activity{logger: log.ChildLogger(ctx.Logger(), "XSLT-transform"), activityName: "transform"}

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

	activityLog.Debugf("Executing Activity [%s] ", ctx.Name())

	input := &Input{}
	err = ctx.GetInputObject(input)
	if err != nil {
		return false, fmt.Errorf("error while getting input object: %s", err.Error())
	}

	if len(input.Xmldocument) == 0 {
		return false, fmt.Errorf("no XML Document provided")
	}

	if len(input.Xsltstylesheet) == 0 {
		return false, fmt.Errorf("no XSLT Stylesheet provided")
	}

	ctx.Logger().Debugf("xmldocument: %v", input.Xmldocument)
	ctx.Logger().Debugf("xsltstylesheet: %v", input.Xsltstylesheet)

	res, err := gokogiri.ParseXml([]byte(input.Xmldocument))
	if err != nil {
		return false, fmt.Errorf("error while parsing xml: %s", err.Error())
	}

	stylesheet, err := xslt.ParseStylesheet([]byte(input.Xsltstylesheet))
	if err != nil {
		return false, fmt.Errorf("error while parsing xslt: %s", err.Error())
	}

	options := xslt.StylesheetOptions{IndentOutput: false, Parameters: nil}

	result, err := stylesheet.Process(res, options)
	if err != nil {
		return false, fmt.Errorf("error while processing xslt: %s", err.Error())
	}

	output := &Output{}

	output.Outputstring = string(result)

	ctx.Logger().Debugf("outputString: %v", output.Outputstring)

	err = ctx.SetOutputObject(output)
	if err != nil {
		return false, fmt.Errorf("error while setting output object: %s", err.Error())
	}

	activityLog.Infof("Completed Activity [%s] ", ctx.Name())

	return true, nil
}
