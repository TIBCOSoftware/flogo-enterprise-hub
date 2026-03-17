package encrypt

import "github.com/project-flogo/core/data/coerce"

type Settings struct {
}

type Input struct {
	Plaintext string `md:"plaintext,required"`
	Publickey string `md:"publickey,required"`
}

type Output struct {
	Ciphertext string `md:"ciphertext,required"`
}

func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	// plaintext string

	i.Plaintext, err = coerce.ToString(values["plaintext"])

	if err != nil {
		return err
	}
	// publickey string

	i.Publickey, err = coerce.ToString(values["publickey"])

	if err != nil {
		return err
	}

	return nil
}

func (i *Input) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"plaintext": i.Plaintext,
		"publickey": i.Publickey,
	}

}

func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	// ciphertext string

	o.Ciphertext, err = coerce.ToString(values["ciphertext"])

	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"ciphertext": o.Ciphertext,
	}

}
