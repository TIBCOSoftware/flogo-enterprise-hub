package transformxml

import (
	"testing"

	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/support/test"

	"github.com/project-flogo/core/activity"
	"github.com/stretchr/testify/assert"
)


var myActivity = &Activity{logger: log.ChildLogger(log.RootLogger(), "Logger-anotherActivity"), activityName: "anotherActivity"}

func TestRegister(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)

	assert.NotNil(t, act)
}

func TestEval(t *testing.T) {

	tc := test.NewActivityContext(myActivity.Metadata())

	aInput := &Input{
		Xslt: []byte(`<?xml version="1.0"?><xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"><xsl:template match="/"><xsl:copy-of select="."/></xsl:template></xsl:stylesheet>`),
		Xml:  []byte(`<?xml version="1.0"?><root><message>Hello, World</message></root>`),
	}
	tc.SetInputObject(aInput)
	ok, _ := myActivity.Eval(tc)
	assert.True(t, ok)
	aOutput := &Output{}
	err := tc.GetOutputObject(aOutput)
	assert.Nil(t, err)

	if err != nil {
		t.Errorf("%s", err.Error())
		t.Fail()
	}
}
