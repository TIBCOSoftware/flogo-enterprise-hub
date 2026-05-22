package xml

import (
	"bytes"
	stdxml "encoding/xml"
	"fmt"
	"strings"

	"github.com/davewins/xslt/dom"
	xpathpkg "github.com/davewins/xslt/xpath"
	"github.com/project-flogo/core/data"
	"github.com/project-flogo/core/data/coerce"
	"github.com/project-flogo/core/data/expression/function"
)

type fnXPATH struct {
}

func init() {
	function.Register(&fnXPATH{})
}

func (s *fnXPATH) Name() string {
	return "xpath"
}
func (s *fnXPATH) Sig() (paramTypes []data.Type, isVariadic bool) {
	return []data.Type{data.TypeString, data.TypeString, data.TypeBool}, false
}

func (s *fnXPATH) Eval(in ...interface{}) (interface{}, error) {

	xpathExpr, err := coerce.ToString(in[0])
	if err != nil {
		return nil, fmt.Errorf("xpath function first parameter [%+v] must be string", in[0])
	}
	xmlStr, err := coerce.ToString(in[1])
	if err != nil {
		return nil, fmt.Errorf("xpath function second parameter [%+v] must be string", in[1])
	}
	returnAsXML, err := coerce.ToBool(in[2])
	if err != nil {
		return nil, fmt.Errorf("xpath function third parameter [%+v] must be boolean", in[2])
	}

	doc, err := dom.Parse([]byte(xmlStr))
	if err != nil {
		return nil, fmt.Errorf("xpath function: invalid XML: %w", err)
	}

	expr, err := xpathpkg.Parse(xpathExpr)
	if err != nil {
		return nil, fmt.Errorf("xpath function: invalid XPath expression: %w", err)
	}

	ctx := xpathpkg.NewContext(doc)
	xpathpkg.RegisterBuiltins(ctx.Funcs)
	ctx.Item = &xpathpkg.NodeItem{Node: doc.Root}
	ctx.Position = 1
	ctx.Size = 1

	seq, err := xpathpkg.Eval(expr, ctx)
	if err != nil {
		return nil, fmt.Errorf("xpath function: evaluation failed: %w", err)
	}

	if len(seq) == 0 {
		return "", nil
	}

	var parts []string
	for _, item := range seq {
		if item.IsNode() {
			n := item.(*xpathpkg.NodeItem).Node
			if returnAsXML {
				parts = append(parts, string(dom.Serialize(n)))
			} else {
				parts = append(parts, n.StringValue())
			}
		} else {
			if returnAsXML {
				parts = append(parts, xmlEscape(item.StringValue()))
			} else {
				parts = append(parts, item.StringValue())
			}
		}
	}

	if returnAsXML && len(parts) > 1 {
		return "<results>" + strings.Join(parts, "") + "</results>", nil
	}
	return strings.Join(parts, "\n"), nil
}

func xmlEscape(s string) string {
	var b bytes.Buffer
	stdxml.EscapeText(&b, []byte(s))
	return b.String()
}
