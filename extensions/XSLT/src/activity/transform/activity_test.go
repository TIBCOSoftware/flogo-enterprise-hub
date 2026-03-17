package transform

import (
	"testing"

	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

const xmlDocument = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><fruits><apple>Granny Smith</apple><pair>Bosc</pair><banana>Cavendish</banana><pair>Anjou</pair><orange>Navel</orange><pair>Bartlett</pair><grape>Concord</grape></fruits>"
const xsltstylesheet = "<xsl:stylesheet version=\"2.0\" xmlns:xsl=\"http://www.w3.org/1999/XSL/Transform\" xmlns:xs=\"http://www.w3.org/1999/XSL/Transform\"><xsl:template match=\"/fruits\"><apples-and-friends><xsl:for-each select=\"*\"><xsl:choose><xsl:when test=\"name() = 'pair'\"><apple-like-fruit/></xsl:when><xsl:otherwise><xsl:copy-of select=\".\"/></xsl:otherwise></xsl:choose></xsl:for-each></apples-and-friends></xsl:template></xsl:stylesheet>"

func TestEval(t *testing.T) {

	transformtActivity := &Activity{logger: log.ChildLogger(log.RootLogger(), "XSLT-transform"), activityName: "transform"}

	log.SetLogLevel(transformtActivity.logger, log.DebugLevel)

	tc := test.NewActivityContext(transformtActivity.Metadata())

	aInput := &Input{
		Xmldocument:    xmlDocument,
		Xsltstylesheet: xsltstylesheet,
	}

	tc.SetInputObject(aInput)

	ok, err := transformtActivity.Eval(tc)
	assert.True(t, ok)

	if err != nil {
		t.Errorf("Failed to perform transform operation: %s", err.Error())
		t.Fail()
	}

	aOutput := &Output{}
	err = tc.GetOutputObject(aOutput)
	assert.Nil(t, err)
	if err != nil {
		t.Errorf("Failed to get output of transform operation: %s", err.Error())
		t.Fail()
	}
}
