/*
 * Copyright © 2017. TIBCO Software Inc.
 * This file is subject to the license terms contained
 * in the license file that is distributed with this file.
 */
package getidtoken

import (
	"fmt"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
	"testing"
)

func TestRegister(t *testing.T) {

	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)

	assert.NotNil(t, act)
}

func TestEval(t *testing.T) {

	act := &Activity{}

	tc := test.NewActivityContext(act.Metadata())

	tc.SetInput("url", "http://example.com")

	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
	}

	assert.True(t, done)
	var output = fmt.Sprint(tc.GetOutput("accessToken"))
	fmt.Println("Output    : ", string(output))

}
