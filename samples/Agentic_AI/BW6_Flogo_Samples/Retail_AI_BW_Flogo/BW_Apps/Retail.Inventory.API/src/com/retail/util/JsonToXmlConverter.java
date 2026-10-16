package com.retail.util;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.w3c.dom.Document;
import org.w3c.dom.Element;

import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.OutputKeys;
import javax.xml.transform.Transformer;
import javax.xml.transform.TransformerFactory;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import java.io.StringWriter;
import java.util.Iterator;
import java.util.Map;

public class JsonToXmlConverter {

    private final ObjectMapper objectMapper = new ObjectMapper();

    public String convertProductsJsonToXml(String json) throws Exception {
        JsonNode root = objectMapper.readTree(json);

        Document document = DocumentBuilderFactory
                .newInstance()
                .newDocumentBuilder()
                .newDocument();

        Element productsElement = document.createElement("products");
        document.appendChild(productsElement);

        if (!root.isArray()) {
            throw new IllegalArgumentException("Expected root JSON value to be an array of products.");
        }

        for (JsonNode productNode : root) {
            Element productElement = document.createElement("product");
            productsElement.appendChild(productElement);
            appendJsonFields(document, productElement, productNode);
        }

        return toXmlString(document);
    }

    private void appendJsonFields(Document document, Element parentElement, JsonNode node) {
        Iterator<Map.Entry<String, JsonNode>> fields = node.fields();

        while (fields.hasNext()) {
            Map.Entry<String, JsonNode> field = fields.next();
            String fieldName = sanitizeXmlElementName(field.getKey());
            JsonNode fieldValue = field.getValue();

            Element childElement = document.createElement(fieldName);
            parentElement.appendChild(childElement);

            if (fieldValue.isObject()) {
                appendJsonFields(document, childElement, fieldValue);
            } else if (fieldValue.isArray()) {
                for (JsonNode arrayItem : fieldValue) {
                    Element itemElement = document.createElement("item");
                    childElement.appendChild(itemElement);

                    if (arrayItem.isObject()) {
                        appendJsonFields(document, itemElement, arrayItem);
                    } else {
                        itemElement.setTextContent(arrayItem.asText());
                    }
                }
            } else if (!fieldValue.isNull()) {
                childElement.setTextContent(fieldValue.asText());
            }
        }
    }

    private String sanitizeXmlElementName(String name) {
        String sanitized = name.replaceAll("[^A-Za-z0-9_.-]", "_");

        if (sanitized.isEmpty() || !Character.isLetter(sanitized.charAt(0))) {
            sanitized = "field_" + sanitized;
        }

        return sanitized;
    }

    private String toXmlString(Document document) throws Exception {
        Transformer transformer = TransformerFactory
                .newInstance()
                .newTransformer();

        transformer.setOutputProperty(OutputKeys.INDENT, "yes");
        transformer.setOutputProperty(OutputKeys.ENCODING, "UTF-8");
        transformer.setOutputProperty(OutputKeys.OMIT_XML_DECLARATION, "no");

        StringWriter writer = new StringWriter();
        transformer.transform(new DOMSource(document), new StreamResult(writer));

        return writer.toString();
    }
}
