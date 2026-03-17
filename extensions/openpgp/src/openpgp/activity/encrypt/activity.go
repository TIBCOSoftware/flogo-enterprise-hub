package encrypt

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"

	"github.com/ProtonMail/go-crypto/openpgp"
	"github.com/ProtonMail/go-crypto/openpgp/armor"
)

var activityMd = activity.ToMetadata(&Input{}, &Output{})

func init() {
	_ = activity.Register(&MyActivity{}, New)
}

// New creates a new activity
func New(ctx activity.InitContext) (activity.Activity, error) {
	return &MyActivity{logger: log.ChildLogger(ctx.Logger(), "openpgp"), activityName: "encrypt"}, nil
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
		return false, err
	}

	entity, err := entityFromPublicKey(input.Publickey)

	if err != nil {
		return false, err
	}



	encrypted, err := encryptMessage(entity, input.Plaintext)
	if err != nil {
		return false, err
	}

	output.Ciphertext = encrypted

	//Set output object
	err = context.SetOutputObject(output)
	if err != nil {
		return false, err
	}

	return true, nil
}

// encryptMessage encrypts plaintext for the given recipient entity,
// returning an ASCII-armored PGP message.
func encryptMessage(recipient *openpgp.Entity, plaintext string) (string, error) {
	var buf bytes.Buffer

	// Wrap output in ASCII armor
	armorWriter, err := armor.Encode(&buf, "PGP MESSAGE", nil)
	if err != nil {
		return "", fmt.Errorf("armor encode: %w", err)
	}

	// Create the encrypted writer targeting the recipient
	recipients := openpgp.EntityList{recipient}
	plaintextWriter, err := openpgp.Encrypt(armorWriter, recipients, nil, nil, nil)
	if err != nil {
		return "", fmt.Errorf("encrypt: %w", err)
	}

	// Write plaintext
	if _, err = io.WriteString(plaintextWriter, plaintext); err != nil {
		return "", fmt.Errorf("write plaintext: %w", err)
	}

	// Close in order: plaintext writer → armor writer
	plaintextWriter.Close()
	armorWriter.Close()

	return buf.String(), nil
}

func entityFromPublicKey(armoredKey string) (*openpgp.Entity, error) {
	// Decode the armor block
	block, err := armor.Decode(strings.NewReader(armoredKey))
	if err != nil {
		return nil, fmt.Errorf("armor decode: %w", err)
	}

	// ReadKeyRing handles both single keys and multi-key blocks
	keyring, err := openpgp.ReadKeyRing(block.Body)
	if err != nil {
		return nil, fmt.Errorf("read keyring: %w", err)
	}
	if len(keyring) == 0 {
		return nil, fmt.Errorf("no keys found in armored block")
	}

	return keyring[0], nil
}
