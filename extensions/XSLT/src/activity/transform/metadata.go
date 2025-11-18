package transform

import "github.com/project-flogo/core/data/coerce"

type Settings struct {
	IndentOutput	bool `md:"indentOutput,requred"`
}

type Input struct {
	Xmldocument    string `md:"xmlDocument,required"`
	Xsltstylesheet string `md:"xsltStylesheet,required"`
}

type Output struct {
	Outputstring string `md:"outputString,required"`
}

func (i *Input) FromMap(values map[string]interface{}) error {
	var err error

	// xmlDocument string

	i.Xmldocument, err = coerce.ToString(values["xmlDocument"])

	if err != nil {
		return err
	}
	// xsltStylesheet string

	i.Xsltstylesheet, err = coerce.ToString(values["xsltStylesheet"])

	if err != nil {
		return err
	}

	return nil
}

func (i *Input) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"xmlDocument":    i.Xmldocument,
		"xsltStylesheet": i.Xsltstylesheet,
	}

}

func (o *Output) FromMap(values map[string]interface{}) error {
	var err error

	// outputString string

	o.Outputstring, err = coerce.ToString(values["outputString"])

	if err != nil {
		return err
	}

	return nil
}

func (o *Output) ToMap() map[string]interface{} {

	return map[string]interface{}{

		"outputString": o.Outputstring,
	}

}
