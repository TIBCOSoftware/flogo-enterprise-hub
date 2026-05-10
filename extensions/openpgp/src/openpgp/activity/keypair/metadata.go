package keypair

import "github.com/project-flogo/core/data/coerce"

type Settings struct {
}

type Input struct {
	Name string `md:"name,required"`
	Comment string `md:"comment,required"`
	Email string `md:"email,required"`
}

type Output struct {
	PublicKey string `md:"publicKey,required"`
	PrivateKey string `md:"privateKey,required"`
}

func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	// name string

	i.Name, err = coerce.ToString(values["name"])

	if err != nil {
		return err
	}
	// comment string

	i.Comment, err = coerce.ToString(values["comment"])

	if err != nil {
		return err
	}
	// email string

	i.Email, err = coerce.ToString(values["email"])

	if err != nil {
		return err
	}
	return nil
}

func (i *Input) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"name": i.Name,
		"comment": i.Comment,
		"email": i.Email,
	}

}

func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	// publicKey string

	o.PublicKey, err = coerce.ToString(values["publicKey"])

	if err != nil {
		return err
	}

	// privateKey string

	o.PrivateKey, err = coerce.ToString(values["privateKey"])

	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"publicKey": o.PublicKey,
		"privateKey": o.PrivateKey,
	}

}
