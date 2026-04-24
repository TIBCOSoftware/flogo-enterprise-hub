package xsdschematransform

import (
	"encoding/xml"
)

// --- XSD Schema Type Definitions ---

// XSDSchema represents the root <xs:schema> element
type XSDSchema struct {
	XMLName              xml.Name            `xml:"schema"`
	ElementFormDefault   string              `xml:"elementFormDefault,attr,omitempty"`
	AttributeFormDefault string              `xml:"attributeFormDefault,attr,omitempty"`
	TargetNamespace      string              `xml:"targetNamespace,attr,omitempty"`
	XmlnsXs              string              `xml:"xmlns:xs,attr"`
	XmlnsXsi             string              `xml:"xmlns:xsi,attr,omitempty"`
	XmlnsTns             string              `xml:"xmlns:tns,attr,omitempty"`
	Elements             []XSDElement        `xml:"element"`
	ComplexTypes         []XSDComplexTypeDef `xml:"complexType,omitempty"`
	SimpleTypes          []XSDSimpleTypeDef  `xml:"simpleType,omitempty"`
	Attributes           []XSDAttribute      `xml:"attribute,omitempty"`
	Groups               []XSDGroup          `xml:"group,omitempty"`
	AttributeGroups      []XSDAttributeGroup `xml:"attributeGroup,omitempty"`
	Imports              []XSDImport         `xml:"import,omitempty"`
	Includes             []XSDInclude        `xml:"include,omitempty"`
}

// XSDElement represents an <xs:element>
type XSDElement struct {
	XMLName           xml.Name        `xml:"element"`
	Name              string          `xml:"name,attr,omitempty"`
	Ref               string          `xml:"ref,attr,omitempty"`
	Type              string          `xml:"type,attr,omitempty"`
	MinOccurs         string          `xml:"minOccurs,attr,omitempty"`
	MaxOccurs         string          `xml:"maxOccurs,attr,omitempty"`
	Nillable          string          `xml:"nillable,attr,omitempty"`
	Default           string          `xml:"default,attr,omitempty"`
	Fixed             string          `xml:"fixed,attr,omitempty"`
	Form              string          `xml:"form,attr,omitempty"`
	Block             string          `xml:"block,attr,omitempty"`
	Final             string          `xml:"final,attr,omitempty"`
	Abstract          string          `xml:"abstract,attr,omitempty"`
	SubstitutionGroup string          `xml:"substitutionGroup,attr,omitempty"`
	ComplexType       *XSDComplexType `xml:"complexType,omitempty"`
	SimpleType        *XSDSimpleType  `xml:"simpleType,omitempty"`
	Annotation        *XSDAnnotation  `xml:"annotation,omitempty"`
	Key               []XSDKey        `xml:"key,omitempty"`
	KeyRef            []XSDKeyRef     `xml:"keyref,omitempty"`
	Unique            []XSDUnique     `xml:"unique,omitempty"`
}

// XSDComplexType represents an <xs:complexType>
type XSDComplexType struct {
	XMLName        xml.Name              `xml:"complexType"`
	Mixed          string                `xml:"mixed,attr,omitempty"`
	Abstract       string                `xml:"abstract,attr,omitempty"`
	Block          string                `xml:"block,attr,omitempty"`
	Final          string                `xml:"final,attr,omitempty"`
	Sequence       *XSDSequence          `xml:"sequence,omitempty"`
	Choice         *XSDChoice            `xml:"choice,omitempty"`
	All            *XSDAll               `xml:"all,omitempty"`
	Group          *XSDGroupRef          `xml:"group,omitempty"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	SimpleContent  *XSDSimpleContent     `xml:"simpleContent,omitempty"`
	ComplexContent *XSDComplexContent    `xml:"complexContent,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDComplexTypeDef represents named complex type definitions
type XSDComplexTypeDef struct {
	XMLName        xml.Name              `xml:"complexType"`
	Name           string                `xml:"name,attr"`
	Mixed          string                `xml:"mixed,attr,omitempty"`
	Abstract       string                `xml:"abstract,attr,omitempty"`
	Block          string                `xml:"block,attr,omitempty"`
	Final          string                `xml:"final,attr,omitempty"`
	Sequence       *XSDSequence          `xml:"sequence,omitempty"`
	Choice         *XSDChoice            `xml:"choice,omitempty"`
	All            *XSDAll               `xml:"all,omitempty"`
	Group          *XSDGroupRef          `xml:"group,omitempty"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	SimpleContent  *XSDSimpleContent     `xml:"simpleContent,omitempty"`
	ComplexContent *XSDComplexContent    `xml:"complexContent,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDSimpleType represents an <xs:simpleType> with restrictions
type XSDSimpleType struct {
	XMLName     xml.Name        `xml:"simpleType"`
	Restriction *XSDRestriction `xml:"restriction,omitempty"`
	List        *XSDList        `xml:"list,omitempty"`
	Union       *XSDUnion       `xml:"union,omitempty"`
	Annotation  *XSDAnnotation  `xml:"annotation,omitempty"`
}

// XSDSimpleTypeDef represents named simple type definitions
type XSDSimpleTypeDef struct {
	XMLName     xml.Name        `xml:"simpleType"`
	Name        string          `xml:"name,attr"`
	Final       string          `xml:"final,attr,omitempty"`
	Restriction *XSDRestriction `xml:"restriction,omitempty"`
	List        *XSDList        `xml:"list,omitempty"`
	Union       *XSDUnion       `xml:"union,omitempty"`
	Annotation  *XSDAnnotation  `xml:"annotation,omitempty"`
}

// XSDSequence represents an <xs:sequence>
type XSDSequence struct {
	XMLName    xml.Name       `xml:"sequence"`
	MinOccurs  string         `xml:"minOccurs,attr,omitempty"`
	MaxOccurs  string         `xml:"maxOccurs,attr,omitempty"`
	Elements   []XSDElement   `xml:"element"`
	Groups     []XSDGroupRef  `xml:"group,omitempty"`
	Choices    []XSDChoice    `xml:"choice,omitempty"`
	Sequences  []XSDSequence  `xml:"sequence,omitempty"`
	Any        []XSDAny       `xml:"any,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDChoice represents an <xs:choice>
type XSDChoice struct {
	XMLName    xml.Name       `xml:"choice"`
	MinOccurs  string         `xml:"minOccurs,attr,omitempty"`
	MaxOccurs  string         `xml:"maxOccurs,attr,omitempty"`
	Elements   []XSDElement   `xml:"element"`
	Groups     []XSDGroupRef  `xml:"group,omitempty"`
	Choices    []XSDChoice    `xml:"choice,omitempty"`
	Sequences  []XSDSequence  `xml:"sequence,omitempty"`
	Any        []XSDAny       `xml:"any,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDAll represents an <xs:all>
type XSDAll struct {
	XMLName    xml.Name       `xml:"all"`
	MinOccurs  string         `xml:"minOccurs,attr,omitempty"`
	MaxOccurs  string         `xml:"maxOccurs,attr,omitempty"`
	Elements   []XSDElement   `xml:"element"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDRestriction represents XSD restrictions (xs:restriction element)
type XSDRestriction struct {
	XMLName        xml.Name              `xml:"restriction"`
	Base           string                `xml:"base,attr"`
	Pattern        []XSDPattern          `xml:"pattern,omitempty"`
	MinLength      *XSDFacet             `xml:"minLength,omitempty"`
	MaxLength      *XSDFacet             `xml:"maxLength,omitempty"`
	Length         *XSDFacet             `xml:"length,omitempty"`
	MinInclusive   *XSDFacet             `xml:"minInclusive,omitempty"`
	MaxInclusive   *XSDFacet             `xml:"maxInclusive,omitempty"`
	MinExclusive   *XSDFacet             `xml:"minExclusive,omitempty"`
	MaxExclusive   *XSDFacet             `xml:"maxExclusive,omitempty"`
	TotalDigits    *XSDFacet             `xml:"totalDigits,omitempty"`
	FractionDigits *XSDFacet             `xml:"fractionDigits,omitempty"`
	WhiteSpace     *XSDFacet             `xml:"whiteSpace,omitempty"`
	Enumerations   []XSDEnumeration      `xml:"enumeration,omitempty"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	Sequence       *XSDSequence          `xml:"sequence,omitempty"`
	Choice         *XSDChoice            `xml:"choice,omitempty"`
	All            *XSDAll               `xml:"all,omitempty"`
	Group          *XSDGroupRef          `xml:"group,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDList represents xs:list
type XSDList struct {
	XMLName    xml.Name       `xml:"list"`
	ItemType   string         `xml:"itemType,attr,omitempty"`
	SimpleType *XSDSimpleType `xml:"simpleType,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDUnion represents xs:union
type XSDUnion struct {
	XMLName     xml.Name        `xml:"union"`
	MemberTypes string          `xml:"memberTypes,attr,omitempty"`
	SimpleTypes []XSDSimpleType `xml:"simpleType,omitempty"`
	Annotation  *XSDAnnotation  `xml:"annotation,omitempty"`
}

// XSDAttribute represents xs:attribute
type XSDAttribute struct {
	XMLName    xml.Name       `xml:"attribute"`
	Name       string         `xml:"name,attr,omitempty"`
	Ref        string         `xml:"ref,attr,omitempty"`
	Type       string         `xml:"type,attr,omitempty"`
	Use        string         `xml:"use,attr,omitempty"`
	Default    string         `xml:"default,attr,omitempty"`
	Fixed      string         `xml:"fixed,attr,omitempty"`
	Form       string         `xml:"form,attr,omitempty"`
	SimpleType *XSDSimpleType `xml:"simpleType,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDGroup represents xs:group
type XSDGroup struct {
	XMLName    xml.Name       `xml:"group"`
	Name       string         `xml:"name,attr"`
	Sequence   *XSDSequence   `xml:"sequence,omitempty"`
	Choice     *XSDChoice     `xml:"choice,omitempty"`
	All        *XSDAll        `xml:"all,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDGroupRef represents xs:group reference
type XSDGroupRef struct {
	XMLName    xml.Name       `xml:"group"`
	Ref        string         `xml:"ref,attr"`
	MinOccurs  string         `xml:"minOccurs,attr,omitempty"`
	MaxOccurs  string         `xml:"maxOccurs,attr,omitempty"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDAttributeGroup represents xs:attributeGroup
type XSDAttributeGroup struct {
	XMLName         xml.Name               `xml:"attributeGroup"`
	Name            string                 `xml:"name,attr"`
	Attributes      []XSDAttribute         `xml:"attribute,omitempty"`
	AttributeGroups []XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute    *XSDAnyAttribute       `xml:"anyAttribute,omitempty"`
	Annotation      *XSDAnnotation         `xml:"annotation,omitempty"`
}

// XSDAttributeGroupRef represents xs:attributeGroup reference
type XSDAttributeGroupRef struct {
	XMLName    xml.Name       `xml:"attributeGroup"`
	Ref        string         `xml:"ref,attr"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDAny represents xs:any
type XSDAny struct {
	XMLName         xml.Name       `xml:"any"`
	Namespace       string         `xml:"namespace,attr,omitempty"`
	ProcessContents string         `xml:"processContents,attr,omitempty"`
	MinOccurs       string         `xml:"minOccurs,attr,omitempty"`
	MaxOccurs       string         `xml:"maxOccurs,attr,omitempty"`
	Annotation      *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDAnyAttribute represents xs:anyAttribute
type XSDAnyAttribute struct {
	XMLName         xml.Name       `xml:"anyAttribute"`
	Namespace       string         `xml:"namespace,attr,omitempty"`
	ProcessContents string         `xml:"processContents,attr,omitempty"`
	Annotation      *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDSimpleContent represents xs:simpleContent
type XSDSimpleContent struct {
	XMLName     xml.Name              `xml:"simpleContent"`
	Extension   *XSDSimpleExtension   `xml:"extension,omitempty"`
	Restriction *XSDSimpleRestriction `xml:"restriction,omitempty"`
	Annotation  *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDComplexContent represents xs:complexContent
type XSDComplexContent struct {
	XMLName     xml.Name               `xml:"complexContent"`
	Mixed       string                 `xml:"mixed,attr,omitempty"`
	Extension   *XSDComplexExtension   `xml:"extension,omitempty"`
	Restriction *XSDComplexRestriction `xml:"restriction,omitempty"`
	Annotation  *XSDAnnotation         `xml:"annotation,omitempty"`
}

// XSDSimpleExtension represents xs:extension in simpleContent
type XSDSimpleExtension struct {
	XMLName        xml.Name              `xml:"extension"`
	Base           string                `xml:"base,attr"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDSimpleRestriction represents xs:restriction in simpleContent
type XSDSimpleRestriction struct {
	XMLName        xml.Name              `xml:"restriction"`
	Base           string                `xml:"base,attr"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	Pattern        []XSDPattern          `xml:"pattern,omitempty"`
	MinLength      *XSDFacet             `xml:"minLength,omitempty"`
	MaxLength      *XSDFacet             `xml:"maxLength,omitempty"`
	Length         *XSDFacet             `xml:"length,omitempty"`
	MinInclusive   *XSDFacet             `xml:"minInclusive,omitempty"`
	MaxInclusive   *XSDFacet             `xml:"maxInclusive,omitempty"`
	MinExclusive   *XSDFacet             `xml:"minExclusive,omitempty"`
	MaxExclusive   *XSDFacet             `xml:"maxExclusive,omitempty"`
	TotalDigits    *XSDFacet             `xml:"totalDigits,omitempty"`
	FractionDigits *XSDFacet             `xml:"fractionDigits,omitempty"`
	WhiteSpace     *XSDFacet             `xml:"whiteSpace,omitempty"`
	Enumerations   []XSDEnumeration      `xml:"enumeration,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDComplexExtension represents xs:extension in complexContent
type XSDComplexExtension struct {
	XMLName        xml.Name              `xml:"extension"`
	Base           string                `xml:"base,attr"`
	Sequence       *XSDSequence          `xml:"sequence,omitempty"`
	Choice         *XSDChoice            `xml:"choice,omitempty"`
	All            *XSDAll               `xml:"all,omitempty"`
	Group          *XSDGroupRef          `xml:"group,omitempty"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDComplexRestriction represents xs:restriction in complexContent
type XSDComplexRestriction struct {
	XMLName        xml.Name              `xml:"extension"`
	Base           string                `xml:"base,attr"`
	Sequence       *XSDSequence          `xml:"sequence,omitempty"`
	Choice         *XSDChoice            `xml:"choice,omitempty"`
	All            *XSDAll               `xml:"all,omitempty"`
	Group          *XSDGroupRef          `xml:"group,omitempty"`
	Attributes     []XSDAttribute        `xml:"attribute,omitempty"`
	AttributeGroup *XSDAttributeGroupRef `xml:"attributeGroup,omitempty"`
	AnyAttribute   *XSDAnyAttribute      `xml:"anyAttribute,omitempty"`
	Annotation     *XSDAnnotation        `xml:"annotation,omitempty"`
}

// XSDPattern represents xs:pattern facet
type XSDPattern struct {
	XMLName xml.Name `xml:"pattern"`
	Value   string   `xml:"value,attr"`
}

// XSDEnumeration represents xs:enumeration facet
type XSDEnumeration struct {
	XMLName xml.Name `xml:"enumeration"`
	Value   string   `xml:"value,attr"`
}

// XSDFacet represents generic XSD facets with a value attribute
type XSDFacet struct {
	Value string `xml:"value,attr"`
}

// XSDAnnotation represents xs:annotation
type XSDAnnotation struct {
	XMLName       xml.Name           `xml:"annotation"`
	Documentation []XSDDocumentation `xml:"documentation,omitempty"`
	AppInfo       []XSDAppInfo       `xml:"appinfo,omitempty"`
}

// XSDDocumentation represents xs:documentation
type XSDDocumentation struct {
	XMLName xml.Name `xml:"documentation"`
	Lang    string   `xml:"xml:lang,attr,omitempty"`
	Source  string   `xml:"source,attr,omitempty"`
	Content string   `xml:",chardata"`
}

// XSDAppInfo represents xs:appinfo
type XSDAppInfo struct {
	XMLName xml.Name `xml:"appinfo"`
	Source  string   `xml:"source,attr,omitempty"`
	Content string   `xml:",chardata"`
}

// XSDKey represents xs:key
type XSDKey struct {
	XMLName    xml.Name       `xml:"key"`
	Name       string         `xml:"name,attr"`
	Selector   XSDSelector    `xml:"selector"`
	Fields     []XSDField     `xml:"field"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDKeyRef represents xs:keyref
type XSDKeyRef struct {
	XMLName    xml.Name       `xml:"keyref"`
	Name       string         `xml:"name,attr"`
	Refer      string         `xml:"refer,attr"`
	Selector   XSDSelector    `xml:"selector"`
	Fields     []XSDField     `xml:"field"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDUnique represents xs:unique
type XSDUnique struct {
	XMLName    xml.Name       `xml:"unique"`
	Name       string         `xml:"name,attr"`
	Selector   XSDSelector    `xml:"selector"`
	Fields     []XSDField     `xml:"field"`
	Annotation *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDSelector represents xs:selector
type XSDSelector struct {
	XMLName xml.Name `xml:"selector"`
	XPath   string   `xml:"xpath,attr"`
}

// XSDField represents xs:field
type XSDField struct {
	XMLName xml.Name `xml:"field"`
	XPath   string   `xml:"xpath,attr"`
}

// XSDImport represents xs:import
type XSDImport struct {
	XMLName        xml.Name       `xml:"import"`
	Namespace      string         `xml:"namespace,attr,omitempty"`
	SchemaLocation string         `xml:"schemaLocation,attr,omitempty"`
	Annotation     *XSDAnnotation `xml:"annotation,omitempty"`
}

// XSDInclude represents xs:include
type XSDInclude struct {
	XMLName        xml.Name       `xml:"include"`
	SchemaLocation string         `xml:"schemaLocation,attr"`
	Annotation     *XSDAnnotation `xml:"annotation,omitempty"`
}

// --- JSON Schema Types ---

// JSONSchema represents a JSON Schema document
type JSONSchema struct {
	Schema               string                 `json:"$schema,omitempty"`
	ID                   string                 `json:"$id,omitempty"`
	Title                string                 `json:"title,omitempty"`
	Description          string                 `json:"description,omitempty"`
	Type                 interface{}            `json:"type,omitempty"` // string or []string
	Properties           map[string]*JSONSchema `json:"properties,omitempty"`
	PatternProperties    map[string]*JSONSchema `json:"patternProperties,omitempty"`
	AdditionalProperties interface{}            `json:"additionalProperties,omitempty"` // bool or *JSONSchema
	Items                interface{}            `json:"items,omitempty"`                // *JSONSchema or []*JSONSchema
	AdditionalItems      interface{}            `json:"additionalItems,omitempty"`      // bool or *JSONSchema
	Required             []string               `json:"required,omitempty"`
	Dependencies         map[string]interface{} `json:"dependencies,omitempty"`
	DependentRequired    map[string][]string    `json:"dependentRequired,omitempty"`
	DependentSchemas     map[string]*JSONSchema `json:"dependentSchemas,omitempty"`
	Enum                 []interface{}          `json:"enum,omitempty"`
	Const                interface{}            `json:"const,omitempty"`
	AnyOf                []*JSONSchema          `json:"anyOf,omitempty"`
	OneOf                []*JSONSchema          `json:"oneOf,omitempty"`
	AllOf                []*JSONSchema          `json:"allOf,omitempty"`
	Not                  *JSONSchema            `json:"not,omitempty"`
	If                   *JSONSchema            `json:"if,omitempty"`
	Then                 *JSONSchema            `json:"then,omitempty"`
	Else                 *JSONSchema            `json:"else,omitempty"`
	Format               string                 `json:"format,omitempty"`
	ContentMediaType     string                 `json:"contentMediaType,omitempty"`
	ContentEncoding      string                 `json:"contentEncoding,omitempty"`
	Definitions          map[string]*JSONSchema `json:"definitions,omitempty"`
	Defs                 map[string]*JSONSchema `json:"$defs,omitempty"`
	Comment              string                 `json:"$comment,omitempty"`
	Examples             []interface{}          `json:"examples,omitempty"`
	Default              interface{}            `json:"default,omitempty"`
	ReadOnly             *bool                  `json:"readOnly,omitempty"`
	WriteOnly            *bool                  `json:"writeOnly,omitempty"`
	Deprecated           *bool                  `json:"deprecated,omitempty"`

	// String validation
	MinLength *int   `json:"minLength,omitempty"`
	MaxLength *int   `json:"maxLength,omitempty"`
	Pattern   string `json:"pattern,omitempty"`

	// Numeric validation
	Minimum          *float64    `json:"minimum,omitempty"`
	Maximum          *float64    `json:"maximum,omitempty"`
	ExclusiveMinimum interface{} `json:"exclusiveMinimum,omitempty"` // bool or float64
	ExclusiveMaximum interface{} `json:"exclusiveMaximum,omitempty"` // bool or float64
	MultipleOf       *float64    `json:"multipleOf,omitempty"`

	// Array validation
	MinItems    *int        `json:"minItems,omitempty"`
	MaxItems    *int        `json:"maxItems,omitempty"`
	UniqueItems *bool       `json:"uniqueItems,omitempty"`
	Contains    *JSONSchema `json:"contains,omitempty"`
	MinContains *int        `json:"minContains,omitempty"`
	MaxContains *int        `json:"maxContains,omitempty"`

	// Object validation
	MinProperties *int        `json:"minProperties,omitempty"`
	MaxProperties *int        `json:"maxProperties,omitempty"`
	PropertyNames *JSONSchema `json:"propertyNames,omitempty"`
}

// --- Avro Schema Types ---

// AvroSchema represents an Avro schema
type AvroSchema struct {
	Type        interface{} `json:"type"`
	Name        string      `json:"name,omitempty"`
	Namespace   string      `json:"namespace,omitempty"`
	Doc         string      `json:"doc,omitempty"`
	Aliases     []string    `json:"aliases,omitempty"`
	Fields      []AvroField `json:"fields,omitempty"`
	Items       interface{} `json:"items,omitempty"`
	Values      interface{} `json:"values,omitempty"`
	Symbols     []string    `json:"symbols,omitempty"`
	Size        *int        `json:"size,omitempty"`
	Default     interface{} `json:"default,omitempty"`
	Order       string      `json:"order,omitempty"`
	LogicalType string      `json:"logicalType,omitempty"`
	Precision   *int        `json:"precision,omitempty"`
	Scale       *int        `json:"scale,omitempty"`
}

// AvroField represents a field in an Avro record
type AvroField struct {
	Name    string      `json:"name"`
	Type    interface{} `json:"type"`
	Doc     string      `json:"doc,omitempty"`
	Default interface{} `json:"default,omitempty"`
	Order   string      `json:"order,omitempty"`
	Aliases []string    `json:"aliases,omitempty"`
}
