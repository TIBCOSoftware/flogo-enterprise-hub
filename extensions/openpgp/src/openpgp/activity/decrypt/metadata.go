package decrypt

import "github.com/project-flogo/core/data/coerce"

type Settings struct {
}

type Input struct {
	Ciphertext string `md:"ciphertext,required"`
	Privatekey string `md:"privatekey,required"`
}

type Output struct {
	Plaintext string `md:"plaintext,required"`
}

func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	// cyphertext string

	i.Ciphertext, err = coerce.ToString(values["ciphertext"])

	if err != nil {
		return err
	}
	// privatekey string

	i.Privatekey, err = coerce.ToString(values["privatekey"])

	if err != nil {
		return err
	}

	return nil
}

func (i *Input) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"ciphertext": i.Ciphertext,
		"privatekey": i.Privatekey,
	}

}

func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	// plaintext string

	o.Plaintext, err = coerce.ToString(values["plaintext"])

	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"plaintext": o.Plaintext,
	}

}
