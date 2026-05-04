package keypair

import (
	"fmt"

	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
)

const entityName = `MyName`
const entityComment = `some comment`
const entityEmail = `email@localhost`

func TestRegister(t *testing.T) {

	ref := activity.GetRef(&MyActivity{})
	act := activity.Get(ref)

	assert.NotNil(t, act)
}

func TestEval(t *testing.T) {

	act := &MyActivity{}

	tc := test.NewActivityContext(act.Metadata())

	tc.SetInput("name", entityName)
	tc.SetInput("comment", entityComment)
	tc.SetInput("email", entityEmail)
	done, err := act.Eval(tc)
	if !done {
		fmt.Println(err)
	}

	assert.True(t, done)

	var actualPublicKey = tc.GetOutput("publicKey")
	assert.NotNil(t, actualPublicKey)
	fmt.Println("publicKey    : ", actualPublicKey)

	var actualPrivateKey = tc.GetOutput("privateKey")
	assert.NotNil(t, actualPrivateKey)
	fmt.Println("privatekey    : ", actualPrivateKey)

}
