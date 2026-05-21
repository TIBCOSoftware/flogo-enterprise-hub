package transformxml

import "github.com/project-flogo/core/data/coerce"

type Settings struct {

}

type Input struct {

	Xslt   []byte                 `md:"XSLT,required"`
	Xml    []byte                 `md:"XML,required"`
	Params map[string]interface{} `md:"Params"`
}

type Output struct {

	Transformedxml []byte `md:"TransformedXML"`
}


func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	i.Xslt, err = coerce.ToBytes(values["XSLT"])
	if err != nil {
		return err
	}

	i.Xml, err = coerce.ToBytes(values["XML"])
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

		"XSLT":   i.Xslt,
		"XML":    i.Xml,
		"Params": i.Params,
	}

}


func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	o.Transformedxml, err = coerce.ToBytes(values["TransformedXML"])
	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"TransformedXML": o.Transformedxml,		
	}

}
