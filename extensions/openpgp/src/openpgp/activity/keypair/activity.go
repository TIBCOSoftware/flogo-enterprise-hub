package keypair

import (
	"fmt"
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
	return &MyActivity{logger: log.ChildLogger(ctx.Logger(), "openpgp"), activityName: "keypair"}, nil
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

	entity, err := generateNewEntity(input.Name, input.Comment, input.Email)
	if err != nil {
		return false, err
	}

	privateKey, err := exportPrivateKey(entity)
	if err != nil {
		return false, err
	}

	publicKey, err := exportPublicKey(entity)
	if err != nil {
		return false, err
	}

	output.PrivateKey = privateKey
	output.PublicKey = publicKey

	//Set output object
	err = context.SetOutputObject(output)
	if err != nil {
		return false, err
	}

	return true, nil
}

func generateNewEntity(name string, comment string, email string) (*openpgp.Entity, error) {

	entity, err := openpgp.NewEntity(name, comment, email, nil)
	if err != nil {
		return nil, err

	}

	return entity, nil

}

// Export armored public key
func exportPublicKey(entity *openpgp.Entity) (string, error) {
	var sb strings.Builder
	w, err := armor.Encode(&sb, "PGP PUBLIC KEY BLOCK", nil)
	if err != nil {
		return "", fmt.Errorf("armor encode: %w", err)
	}
	if err := entity.Serialize(w); err != nil {
		return "", fmt.Errorf("serialize: %w", err)
	}
	w.Close()
	return sb.String(), nil
}

// Export armored private key
func exportPrivateKey(entity *openpgp.Entity) (string, error) {
	if entity.PrivateKey == nil {
		return "", fmt.Errorf("entity has no private key")
	}
	var sb strings.Builder
	w, err := armor.Encode(&sb, "PGP PRIVATE KEY BLOCK", nil)
	if err != nil {
		return "", fmt.Errorf("armor encode: %w", err)
	}
	if err := entity.SerializePrivate(w, nil); err != nil {
		return "", fmt.Errorf("serialize private: %w", err)
	}
	w.Close()
	return sb.String(), nil
}
