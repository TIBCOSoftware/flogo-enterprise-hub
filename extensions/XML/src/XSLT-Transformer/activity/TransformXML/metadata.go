package transformxml

import "github.com/project-flogo/core/data/coerce"

type Settings struct {
}

type Input struct {
	XSLT   []byte                 `md:"XSLT,required"`
	XML    []byte                 `md:"XML,required"`
	Params map[string]interface{} `md:"Params"`
}

type Output struct {
	TransformedXML []byte `md:"TransformedXML"`
}

func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	i.XSLT, err = coerce.ToBytes(values["XSLT"])
	if err != nil {
		return err
	}

	i.XML, err = coerce.ToBytes(values["XML"])
	if err != nil {
		return err
	}

	i.Params, err = coerce.ToObject(values["Params"])
	if err != nil {
		return err
	}

	return nil
}

func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"XSLT":   i.XSLT,
		"XML":    i.XML,
		"Params": i.Params,
	}
}

func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	o.TransformedXML, err = coerce.ToBytes(values["TransformedXML"])
	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"TransformedXML": o.TransformedXML,
	}
}
