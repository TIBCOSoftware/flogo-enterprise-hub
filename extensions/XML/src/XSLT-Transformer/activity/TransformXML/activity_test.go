package transformxml

import (
	"testing"

	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/support/log"
	"github.com/project-flogo/core/support/test"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var myActivity = &Activity{
	logger:       log.ChildLogger(log.RootLogger(), "Logger-anotherActivity"),
	activityName: "anotherActivity",
}

// catalogXML is a product catalog used across multiple tests.
var catalogXML = []byte(`<?xml version='1.0'?>
<catalog>
  <product><name>Widget A</name><category>Electronics</category><price>29.99</price></product>
  <product><name>Gadget B</name><category>Electronics</category><price>99.99</price></product>
  <product><name>Gizmo C</name><category>Tools</category><price>15.00</price></product>
</catalog>`)

// catalogXSLT filters products by optional 'category' (string) and 'maxPrice' (number) parameters.
// Defaults return all products.
// Note: use select='"..."' for string defaults and select='N' for numeric defaults — text-content
// defaults create document nodes that cause string-comparison failures in this XSLT library.
var catalogXSLT = []byte(`<?xml version='1.0'?>
<xsl:stylesheet version='2.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>
  <xsl:param name='category' select='"All"'/>
  <xsl:param name='maxPrice' select='9999'/>
  <xsl:output method='xml'/>
  <xsl:template match='/'>
    <results>
      <xsl:for-each select='catalog/product[
        ($category = "All" or category = $category) and
        number(price) &lt;= number($maxPrice)
      ]'>
        <item><xsl:value-of select='name'/></item>
      </xsl:for-each>
    </results>
  </xsl:template>
</xsl:stylesheet>`)

// evalOK is a helper for tests that expect a successful transformation.
func evalOK(t *testing.T, input *Input) string {
	t.Helper()
	tc := test.NewActivityContext(myActivity.Metadata())
	tc.SetInputObject(input)
	ok, err := myActivity.Eval(tc)
	require.NoError(t, err)
	assert.True(t, ok)
	output := &Output{}
	require.NoError(t, tc.GetOutputObject(output))
	return string(output.TransformedXML)
}

func TestRegister(t *testing.T) {
	ref := activity.GetRef(&Activity{})
	act := activity.Get(ref)
	assert.NotNil(t, act)
}

// TestEval_NoParams verifies a basic transformation with no parameters.
func TestEval_NoParams(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:[]byte(`<?xml version='1.0'?>
<xsl:stylesheet version='2.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>
  <xsl:output method='xml'/>
  <xsl:template match='/'>
    <output><xsl:value-of select='root/message'/></output>
  </xsl:template>
</xsl:stylesheet>`),
		XML: []byte(`<?xml version='1.0'?><root><message>Hello, World</message></root>`),
	})
	assert.Contains(t, result, "Hello, World")
}

// TestEval_DefaultParams verifies all products are returned when no params are supplied
// and the stylesheet defaults apply.
func TestEval_DefaultParams(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:  catalogXSLT,
		XML:  catalogXML,
		Params: nil,
	})
	assert.Contains(t, result, "Widget A")
	assert.Contains(t, result, "Gadget B")
	assert.Contains(t, result, "Gizmo C")
}

// TestEval_NilParams verifies that nil-valued params (e.g. from Flogo HTTP trigger query params
// that were defined in the schema but absent from the request) do not override XSLT defaults.
func TestEval_NilParams(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:catalogXSLT,
		XML:catalogXML,
		Params: map[string]interface{}{
			"category": nil,
			"maxPrice": nil,
		},
	})
	assert.Contains(t, result, "Widget A")
	assert.Contains(t, result, "Gadget B")
	assert.Contains(t, result, "Gizmo C")
}

// TestEval_PartialNilParams verifies that a nil category does not override the "All" default
// when maxPrice is explicitly provided.
func TestEval_PartialNilParams(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:catalogXSLT,
		XML:catalogXML,
		Params: map[string]interface{}{
			"category": nil,
			"maxPrice": 99.0,
		},
	})
	assert.Contains(t, result, "Widget A")    // 29.99 — under limit
	assert.NotContains(t, result, "Gadget B") // 99.99 — over limit
	assert.Contains(t, result, "Gizmo C")    // 15.00 — under limit
}

// TestEval_StringParam filters the catalog to a single category via a string parameter.
func TestEval_StringParam(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:  catalogXSLT,
		XML:  catalogXML,
		Params: map[string]interface{}{"category": "Electronics"},
	})
	assert.Contains(t, result, "Widget A")
	assert.Contains(t, result, "Gadget B")
	assert.NotContains(t, result, "Gizmo C")
}

// TestEval_NumericParam filters the catalog by maximum price via a numeric parameter.
func TestEval_NumericParam(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:  catalogXSLT,
		XML:  catalogXML,
		Params: map[string]interface{}{"maxPrice": 50.0},
	})
	assert.Contains(t, result, "Widget A")    // 29.99 — under limit
	assert.NotContains(t, result, "Gadget B") // 99.99 — over limit
	assert.Contains(t, result, "Gizmo C")    // 15.00 — under limit
}

// TestEval_MultipleParams combines both parameters so only Electronics under $50 are returned.
func TestEval_MultipleParams(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:catalogXSLT,
		XML:catalogXML,
		Params: map[string]interface{}{
			"category": "Electronics",
			"maxPrice": 50.0,
		},
	})
	assert.Contains(t, result, "Widget A")    // Electronics, 29.99 — matches both
	assert.NotContains(t, result, "Gadget B") // Electronics, 99.99 — over price limit
	assert.NotContains(t, result, "Gizmo C")  // Tools — wrong category
}

// TestEval_InvalidXSLT verifies that a malformed stylesheet returns a compilation error.
func TestEval_InvalidXSLT(t *testing.T) {
	tc := test.NewActivityContext(myActivity.Metadata())
	tc.SetInputObject(&Input{
		XSLT:[]byte(`this is not valid xslt`),
		XML:[]byte(`<?xml version='1.0'?><root/>`),
	})
	_, err := myActivity.Eval(tc)
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "compilation")
}

// TestEval_InvalidXML documents that the underlying XSLT library parses XML leniently:
// input that is not well-formed XML still produces output rather than returning an error.
func TestEval_InvalidXML(t *testing.T) {
	result := evalOK(t, &Input{
		XSLT:catalogXSLT,
		XML:[]byte(`this is not valid xml`),
	})
	assert.NotEmpty(t, result)
}
