package xmlfilter

import (
	"fmt"
	"strings"

	"github.com/antchfx/xmlquery"
	"github.com/project-flogo/core/activity"
	"github.com/project-flogo/core/data/coerce"
)

const (
	ivXMLString       = "xmlString"
	ivXPathConditions = "xpathConditions" // New name for multiple conditions
	ivConditionLogic  = "conditionLogic"  // New input for AND/OR
	ovMatch           = "match"
	ovFilteredXML     = "filteredXmlString"
)

// XPathConditionItem is a helper struct for parsed conditions
type XPathConditionItem struct {
	Expression string
}

// Activity is a stub for your Activity implementation
type Activity struct {
}

// Updated Input struct for metadata generation
var activityMd = activity.ToMetadata(&Input{}, &Output{})

func init() {
	_ = activity.Register(&Activity{}, New)
}

// New creates a new Activity
func New(ctx activity.InitContext) (activity.Activity, error) {
	ctx.Logger().Debugf("Creating new XMLFilter (Multi-Condition) activity")
	return &Activity{}, nil
}

// Metadata implements activity.Activity.Metadata
func (a *Activity) Metadata() *activity.Metadata {
	return activityMd
}

// Eval implements activity.Activity.Eval
func (a *Activity) Eval(ctx activity.Context) (done bool, err error) {
	logger := ctx.Logger()
	logger.Debugf("Executing XMLFilter (Multi-Condition) activity")

	// --- Get Inputs ---
	xmlStringInput, ok := ctx.GetInput(ivXMLString).(string)
	if !ok {
		logger.Errorf("XMLString input not a string or not provided")
		return false, activity.NewError("XMLString input not a string or not provided", "XMLFILTER-4001", nil)
	}

	// Get Condition Logic (AND/OR)
	conditionLogicInputRaw, _ := ctx.GetInput(ivConditionLogic).(string) // Allow it to be missing
	conditionLogicInput := strings.ToUpper(conditionLogicInputRaw)
	if conditionLogicInput != "AND" && conditionLogicInput != "OR" {
		logger.Warnf("ConditionLogic input is invalid ('%s') or not provided. Defaulting to 'AND'.", conditionLogicInputRaw)
		conditionLogicInput = "AND"
	}

	// Get XPath Conditions Array
	xpathConditionsRaw, ok := ctx.GetInput(ivXPathConditions).([]interface{})
	if !ok {
		// This check might be redundant if input is 'required:true' in activity.json,
		// but good for robustness if it could somehow be nil but not the correct type.
		logger.Errorf("XPathConditions input not provided or is not an array")
		return false, activity.NewError("XPathConditions input is required and must be an array of objects", "XMLFILTER-4003", nil)
	}

	if len(xpathConditionsRaw) == 0 {
		logger.Error("XPathConditions array is empty. At least one condition is required.")
		// Or, based on requirements:
		// If AND logic: an empty set of conditions could be true.
		// If OR logic: an empty set of conditions could be false.
		// For now, let's treat empty as a configuration error needing at least one condition.
		return false, activity.NewError("XPathConditions array cannot be empty. At least one condition is required.", "XMLFILTER-4006", nil)
	}

	// Parse and validate each item in the XPathConditions array
	var parsedConditions []XPathConditionItem
	for i, condRaw := range xpathConditionsRaw {
		condMap, mapOk := condRaw.(map[string]interface{})
		if !mapOk {
			errMsg := fmt.Sprintf("XPathConditions element at index %d is not a valid object structure.", i)
			logger.Error(errMsg)
			return false, activity.NewError(errMsg, "XMLFILTER-4004", nil)
		}
		expr, exprOk := condMap["expression"].(string)
		if !exprOk || strings.TrimSpace(expr) == "" {
			errMsg := fmt.Sprintf("XPathConditions element at index %d is missing a non-empty 'expression' string.", i)
			logger.Error(errMsg)
			return false, activity.NewError(errMsg, "XMLFILTER-4005", nil)
		}
		parsedConditions = append(parsedConditions, XPathConditionItem{Expression: strings.TrimSpace(expr)})
	}

	logger.Debugf("Input XML: (length %d)", len(xmlStringInput))
	logger.Debugf("Parsed XPath Conditions: %v", parsedConditions)
	logger.Debugf("Condition Logic: %s", conditionLogicInput)

	if xmlStringInput == "" {
		logger.Warn("Input XML string is empty. No match possible.")
		ctx.SetOutput(ovMatch, false)
		ctx.SetOutput(ovFilteredXML, "")
		return true, nil
	}

	// Parse XML document once
	doc, err := xmlquery.Parse(strings.NewReader(xmlStringInput))
	if err != nil {
		logger.Errorf("Error parsing XML: %v. XML: %s", err, xmlStringInput)
		ctx.SetOutput(ovMatch, false)
		ctx.SetOutput(ovFilteredXML, "")
		// Return the parsing error as it's fundamental
		return true, activity.NewError("XML parsing failed", "XMLFILTER-5001", map[string]interface{}{"details": err.Error()})
	}

	// Evaluate XPath Conditions based on logic
	var overallMatch bool
	if conditionLogicInput == "AND" {
		overallMatch = true // For AND, start true. Any false condition makes it false.
	} else { // OR
		overallMatch = false // For OR, start false. Any true condition makes it true.
	}

	for i, condition := range parsedConditions {
		logger.Debugf("Evaluating condition #%d: [%s]", i+1, condition.Expression)
		nodes, evalErr := xmlquery.QueryAll(doc, condition.Expression)
		currentConditionMatch := false

		if evalErr != nil {
			// Log the error for the specific XPath but treat it as a non-match for this condition
			logger.Warnf("Error evaluating XPath expression '%s' (condition #%d): %v. This condition is considered false.", condition.Expression, i+1, evalErr)
			// currentConditionMatch remains false
		} else {
			if len(nodes) > 0 {
				currentConditionMatch = true
			}
		}
		logger.Debugf("Condition #%d ('%s') individual match: %t", i+1, condition.Expression, currentConditionMatch)

		if conditionLogicInput == "AND" {
			overallMatch = overallMatch && currentConditionMatch
			if !overallMatch {
				logger.Debugf("AND logic: Overall match became false at condition #%d. Short-circuiting.", i+1)
				break // Short-circuit for AND
			}
		} else { // OR
			overallMatch = overallMatch || currentConditionMatch
			if overallMatch {
				logger.Debugf("OR logic: Overall match became true at condition #%d. Short-circuiting.", i+1)
				break // Short-circuit for OR
			}
		}
	}

	// Set Outputs
	if overallMatch {
		logger.Infof("Overall XPath conditions met with logic '%s'. Outputting original XML.", conditionLogicInput)
		ctx.SetOutput(ovMatch, true)
		ctx.SetOutput(ovFilteredXML, xmlStringInput)
	} else {
		logger.Infof("Overall XPath conditions NOT met with logic '%s'. Outputting empty string.", conditionLogicInput)
		ctx.SetOutput(ovMatch, false)
		ctx.SetOutput(ovFilteredXML, "")
	}

	return true, nil
}

// Input struct for marshalling/unmarshalling and metadata generation
type Input struct {
	XMLString       string        `md:"xmlString,required"`
	XPathConditions []interface{} `md:"xpathConditions,required"` // Array of objects e.g. [{"expression": "/path1"}, {"expression": "/path2"}]
	ConditionLogic  string        `md:"conditionLogic"`           // "AND" or "OR", defaults to AND if not provided
}

// ToMap converts Input struct to a map (used by Flogo for metadata)
func (i *Input) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"xmlString":       i.XMLString,
		"xpathConditions": i.XPathConditions,
		"conditionLogic":  i.ConditionLogic,
	}
}

// FromMap populates Input struct from a map (used by Flogo for metadata)
func (i *Input) FromMap(values map[string]interface{}) error {
	var err error
	i.XMLString, err = coerce.ToString(values["xmlString"])
	if err != nil {
		return err
	}

	rawConditions, err := coerce.ToArray(values["xpathConditions"])
	if err != nil {
		// This error might occur if the input is not an array type at all.
		// The Eval function handles the case where it's an array but empty or items are malformed.
		return fmt.Errorf("xpathConditions must be an array: %w", err)
	}
	i.XPathConditions = rawConditions // Store as []interface{} for metadata consistency

	// ConditionLogic is optional, coerce handles if it's missing (becomes empty string)
	// Eval logic will default it to "AND" if empty or invalid.
	i.ConditionLogic, _ = coerce.ToString(values["conditionLogic"])
	// No validation for AND/OR here, Eval handles it to provide a default.
	return nil
}

// Output struct for marshalling/unmarshalling (remains the same)
type Output struct {
	Match             bool   `md:"match"`
	FilteredXMLString string `md:"filteredXmlString"`
}

// ToMap converts Output struct to a map
func (o *Output) ToMap() map[string]interface{} {
	return map[string]interface{}{
		"match":             o.Match,
		"filteredXmlString": o.FilteredXMLString,
	}
}

// FromMap populates Output struct from a map
func (o *Output) FromMap(values map[string]interface{}) error {
	var err error
	o.Match, err = coerce.ToBool(values["match"])
	if err != nil {
		return err
	}
	o.FilteredXMLString, err = coerce.ToString(values["filteredXmlString"])
	if err != nil {
		return err
	}
	return nil
}
