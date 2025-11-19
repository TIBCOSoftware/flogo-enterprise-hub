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

	ctx.Logger().Info("Executing XSLT Transform activity")

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

	xmlDoc, err := gokogiri.ParseXml([]byte(input.Xmldocument))
	if err != nil {
		ctx.Logger().Error(err)
		return false, activity.NewActivityError("Failed to parse Xml data", "XSLT-001", activity.ConfigError, nil)
	}

	styleDoc, err := gokogiri.ParseXml([]byte(input.Xsltstylesheet))
	if err != nil {
		ctx.Logger().Error(err)
		return false, activity.NewActivityError("Failed to read Xslt file", "XSLT-002", activity.ConfigError, nil)
	}

	stylesheet, err := xslt.ParseStylesheet(styleDoc, input.Xsltstylesheet)
	if err != nil {
		ctx.Logger().Error(err)
		return false, activity.NewActivityError("Failed to parse Xslt stylesheet", "XSLT-003", activity.ConfigError, nil)
	}

	options := xslt.StylesheetOptions{IndentOutput: false, Parameters: nil}

	result, err := stylesheet.Process(xmlDoc, options)
	if err != nil {
		ctx.Logger().Error(err)
		return false, activity.NewActivityError("error while processing xslt", "XSLT-004", activity.ConfigError, nil)
	}

	output := &Output{}

	output.Outputstring = string(result)

	ctx.Logger().Debugf("outputString: %v", output.Outputstring)

	err = ctx.SetOutputObject(output)
	if err != nil {
		ctx.Logger().Error(err)
		return false, activity.NewActivityError("error while setting output object", "XSLT-005", activity.ConfigError, nil)
	}

	activityLog.Info("XSLT Transform activity complete")

	return true, nil
}
