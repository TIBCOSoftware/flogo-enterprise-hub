package decrypt

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"github.com/ProtonMail/go-crypto/openpgp"
	"github.com/ProtonMail/go-crypto/openpgp/armor"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
)

var activityMd = activity.ToMetadata(&Input{}, &Output{})

func init() {
	_ = activity.Register(&MyActivity{}, New)
}

// New creates a new activity
func New(ctx activity.InitContext) (activity.Activity, error) {
	return &MyActivity{logger: log.ChildLogger(ctx.Logger(), "openpgp"), activityName: "decrypt"}, nil
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

	entity, err := entityFromPrivateKey(input.Privatekey)

	if err != nil {
		return false, err
	}

	decrypted, err := decryptMessage(entity, input.Ciphertext)
	if err != nil {
		return false, err
	}

	output.Plaintext = decrypted

	//Set output object
	err = context.SetOutputObject(output)
	if err != nil {
		return false, err
	}

	return true, nil
}

// decryptMessage decrypts an ASCII-armored PGP message using the given entity.
func decryptMessage(entity *openpgp.Entity, armored string) (string, error) {
	// Decode the armor
	block, err := armor.Decode(bytes.NewBufferString(armored))
	if err != nil {
		return "", fmt.Errorf("armor decode: %w", err)
	}

	// Provide the private key for decryption
	keyring := openpgp.EntityList{entity}
	md, err := openpgp.ReadMessage(block.Body, keyring, nil, nil)
	if err != nil {
		return "", fmt.Errorf("read message: %w", err)
	}

	// Read decrypted content
	plaintext, err := io.ReadAll(md.UnverifiedBody)
	if err != nil {
		return "", fmt.Errorf("read body: %w", err)
	}

	return string(plaintext), nil
}

func entityFromPrivateKey(armoredKey string) (*openpgp.Entity, error) {
	keyring, err := openpgp.ReadArmoredKeyRing(strings.NewReader(armoredKey))
	if err != nil {
		return nil, fmt.Errorf("read armored key ring: %w", err)
	}
	if len(keyring) == 0 {
		return nil, fmt.Errorf("no keys found")
	}

	entity := keyring[0]
	if entity.PrivateKey == nil {
		return nil, fmt.Errorf("no private key found — this is a public key only")
	}

	return entity, nil
}
