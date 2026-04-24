package main

import (
	"encoding/json"
	"fmt"
	"log"

	"github.com/project-flogo/core/support/test"
	xsdtransform "github.com/project-flogo/custom-extensions/activity/xsdschematransform"
)

func main() {
	// Sample XSD Schema
	xsdSchema := `<?xml version="1.0" encoding="UTF-8"?>
<xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema"
           targetNamespace="http://example.com/customer"
           elementFormDefault="qualified">
    
    <xs:element name="customer" type="CustomerType"/>
    
    <xs:complexType name="CustomerType">
        <xs:sequence>
            <xs:element name="name" type="xs:string"/>
            <xs:element name="age" type="xs:int" minOccurs="0"/>
            <xs:element name="email" type="xs:string"/>
            <xs:element name="address" type="AddressType" minOccurs="0"/>
            <xs:element name="phoneNumbers" type="PhoneNumberList" minOccurs="0"/>
        </xs:sequence>
        <xs:attribute name="id" type="xs:string" use="required"/>
        <xs:attribute name="vip" type="xs:boolean" default="false"/>
    </xs:complexType>
    
    <xs:complexType name="AddressType">
        <xs:sequence>
            <xs:element name="street" type="xs:string"/>
            <xs:element name="city" type="xs:string"/>
            <xs:element name="zipCode" type="ZipCodeType"/>
            <xs:element name="country" type="xs:string" default="US"/>
        </xs:sequence>
    </xs:complexType>
    
    <xs:complexType name="PhoneNumberList">
        <xs:sequence>
            <xs:element name="phone" type="PhoneType" maxOccurs="unbounded"/>
        </xs:sequence>
    </xs:complexType>
    
    <xs:complexType name="PhoneType">
        <xs:simpleContent>
            <xs:extension base="xs:string">
                <xs:attribute name="type" type="PhoneTypeEnum" default="home"/>
            </xs:extension>
        </xs:simpleContent>
    </xs:complexType>
    
    <xs:simpleType name="ZipCodeType">
        <xs:restriction base="xs:string">
            <xs:pattern value="[0-9]{5}(-[0-9]{4})?"/>
        </xs:restriction>
    </xs:simpleType>
    
    <xs:simpleType name="PhoneTypeEnum">
        <xs:restriction base="xs:string">
            <xs:enumeration value="home"/>
            <xs:enumeration value="work"/>
            <xs:enumeration value="mobile"/>
        </xs:restriction>
    </xs:simpleType>
</xs:schema>`

	// Create activity instance
	act := &xsdtransform.Activity{}
	tc := test.NewActivityContext(act.Metadata())

	// Configure for comprehensive transformation
	tc.SetInput("xsdString", xsdSchema)
	tc.SetInput("outputFormat", "both")
	tc.SetInput("validateInput", true)
	tc.SetInput("jsonSchemaVersion", "2020-12")
	tc.SetInput("jsonSchemaTitle", "Customer Schema")
	tc.SetInput("jsonSchemaId", "https://example.com/schemas/customer")
	tc.SetInput("avroRecordName", "Customer")
	tc.SetInput("avroNamespace", "com.example.customer")
	tc.SetInput("avroLogicalTypes", true)
	tc.SetInput("includeAttributes", true)
	tc.SetInput("handleChoice", "union")
	tc.SetInput("optimizeOutput", true)

	// Execute transformation
	fmt.Println("🔄 Transforming XSD Schema...")
	done, err := act.Eval(tc)
	if err != nil {
		log.Fatalf("Activity execution failed: %v", err)
	}
	if !done {
		log.Fatal("Activity execution not completed")
	}

	// Check for errors
	if tc.GetOutput("error").(bool) {
		log.Fatalf("Transformation failed: %s", tc.GetOutput("errorMessage").(string))
	}

	fmt.Println("✅ Transformation completed successfully!")
	fmt.Println()

	// Display JSON Schema result
	fmt.Println("📋 Generated JSON Schema:")
	fmt.Println("=" + string(make([]rune, 50)) + "=")
	jsonSchema := tc.GetOutput("jsonSchemaString").(string)

	// Pretty print JSON Schema
	var jsonObj interface{}
	if err := json.Unmarshal([]byte(jsonSchema), &jsonObj); err == nil {
		if prettyJSON, err := json.MarshalIndent(jsonObj, "", "  "); err == nil {
			fmt.Println(string(prettyJSON))
		}
	}
	fmt.Println()

	// Display Avro Schema result
	fmt.Println("🗂️  Generated Avro Schema:")
	fmt.Println("=" + string(make([]rune, 50)) + "=")
	avroSchema := tc.GetOutput("avroSchemaString").(string)

	// Pretty print Avro Schema
	var avroObj interface{}
	if err := json.Unmarshal([]byte(avroSchema), &avroObj); err == nil {
		if prettyAvro, err := json.MarshalIndent(avroObj, "", "  "); err == nil {
			fmt.Println(string(prettyAvro))
		}
	}
	fmt.Println()

	// Display validation results
	fmt.Println("🔍 Validation Results:")
	fmt.Println("=" + string(make([]rune, 30)) + "=")
	validationResult := tc.GetOutput("validationResult").(string)
	if validationResult != "" {
		var validationObj interface{}
		if err := json.Unmarshal([]byte(validationResult), &validationObj); err == nil {
			if prettyValidation, err := json.MarshalIndent(validationObj, "", "  "); err == nil {
				fmt.Println(string(prettyValidation))
			}
		}
	}
	fmt.Println()

	// Display conversion statistics
	fmt.Println("📊 Conversion Statistics:")
	fmt.Println("=" + string(make([]rune, 35)) + "=")
	conversionStats := tc.GetOutput("conversionStats").(string)
	if conversionStats != "" {
		var statsObj interface{}
		if err := json.Unmarshal([]byte(conversionStats), &statsObj); err == nil {
			if prettyStats, err := json.MarshalIndent(statsObj, "", "  "); err == nil {
				fmt.Println(string(prettyStats))
			}
		}
	}

	fmt.Println("\n🎉 XSD Schema transformation demonstration completed!")
}
