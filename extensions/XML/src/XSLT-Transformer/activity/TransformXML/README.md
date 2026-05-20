# TIBCO Flogo® Extension for XSLT-Transformer - Provides an XML Mapping capability through the use of XSLT 2.0 Stylesheets

Provides an XML Mapping capability through the use of XSLT 2.0 Stylesheets

## Activity Transform XML

Transforms XML through the use of a Stylsheet

Accepts an XML Document and an XSLT Document as []byte and provides the result. Provides support for XSLT 2.0 and XPATH 2.0


### Input Settings

The Input tab has the following fields:

| Field	| Type | Required	| Description |
|-------|------|-----------|-------------|
| XSLT | bytes | true | The XSLT to apply |
| XML | bytes | true | The XML to transform |




### Input

None


### Output Settings
The Output Settings tab has the following field:

| Field	| Type | Description |
|-------|-----------|-------------|
| TransformedXML | object | The result of the transformation |



## Loop

Refer to the section on "Using the Loop Feature in an Activity" in the TIBCO Flogo® Enterprise User's Guide for information on the Loop tab.