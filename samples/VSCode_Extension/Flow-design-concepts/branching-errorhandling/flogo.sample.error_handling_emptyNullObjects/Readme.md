# Error Handling of Null or Empty JSON Objects Within Condition Paths

## Overview

HowTo_Handle_NullEmptyJSON_ObjArray is a sample TIBCO Flogo® application that demonstrates how to handle null and empty JSON objects and JSON arrays while evaluating conditions in a flow.

The app HowTo_Handle_NullEmptyJSON_ObjArray.flogo has three flows. The app showcases three different techniques to safely check and branch logic when incoming JSON data contains:

**1. Null objects**  
**2. Empty JSON objects**  
**3. Empty JSON arrays**

The application uses a Timer trigger to execute multiple flows automatically. Each flow demonstrates a specific scenario for handling empty or null JSON data.

## Flow Descriptions

**1.** Handle_EmptyNull_In_JSONArrayObject: Demonstrates how to handle an empty JSON array. set_Input (Mapper): Initializes a JSON array named book. Mapper: Iterates over the input array using a foreach mapping and produces an output array. Conditional Branch: Uses the expression (array.count($activity[Mapper].output.book) == 0) to check whether the array is empty or null. Logs a message indicating that the array is empty or null and ends the flow execution. Otherwise Branch: Logs the incoming array contents and returns the result.

**2.** Handle_EmptyNull_In_JSONObject_1: Demonstrates how to handle a null JSON object using string-based comparison. set_Input (Mapper): Initializes a sample JSON object named book. Mapper: Maps the book object to the flow output. Conditional Branch: Uses the expression (utility.renderJSON($activity[set_Input].output.book, false) == 'null') If the book object is null, the flow follows the conditional branch. LogMessage: Logs a message indicating that the book object is empty or null and ends the flow execution. Otherwise Branch: Logs the incoming book JSON when the object is not null and returns the result.

**3.** Handle_EmptyNull_In_JSONObject_2 : Demonstrates how to detect a JSON object with a null field value. set_Input (Mapper): Initializes the input JSON structure. Mapper: Maps the input to an output JSON object. Conditional Branch: Evaluates the following condition: (utility.renderJSON($activity[Mapper].output, false) == '{"book":null}') This checks whether the book field exists but contains a null value. LogMessage: Logs a message indicating that the JSON object contains a null value and ends the flow. Otherwise Branch: Logs the valid incoming JSON and returns the output.

## Copy App 

**1.** Copy the HowTo_Handle_NullEmptyJSON_ObjArray.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/CopyApp.png)

**2.** Click on the HowTo_Handle_NullEmptyJSON_ObjArray.flogo app. On the app details page, the three flows should appear as shown in the screenshot below.

![Three Flows](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/ThreeFlows.png)

**3.** Each flow represents a way to check for null or empty JSON objects in the condition path:

**i. Handle_EmptyNull_In_JSONArrayObject flow :**

![Handle_EmptyNull_In_JSONArrayObject condition 1](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow1Condition1.png)

![Handle_EmptyNull_In_JSONArrayObject condition 2](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow1Condition2.png)

**ii. Handle_EmptyNull_In_JSONObject_1 flow :**

![Handle_EmptyNull_In_JSONObject_1 condition 1](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow2Condition1.png)

![Handle_EmptyNull_In_JSONObject_1 condition 2](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow2Condition2.png)

**iii. Handle_EmptyNull_In_JSONObject_2 flow :**

![Handle_EmptyNull_In_JSONObject_2 condition 1](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow3Condition1.png)

![Handle_EmptyNull_In_JSONObject_2 condition 2](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/Flow3Condition2.png)

**4.** As shown in the screenshots below, you can improve the handling of null and empty objects by using error messages in unit tests:

![Handle_EmptyNull_In_JSONArrayObject Unit Test](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/UnitTest1.png)

![Handle_EmptyNull_In_JSONObject_1 Unit Test](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/UnitTest2.png)

![Handle_EmptyNull_In_JSONObject_2 Unit Test](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.error_handling_emptyNullObjects/UnitTest3.png)


## Help

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#flogo-vscode-user-guide/app-development/creating-flows-triggers/flows/catching-errors.htm?TocPath=User%2520Guide%257CApp%2520Development%257CCreating%2520Flows%2520and%2520Triggers%257CFlows%257CCatching%2520Errors%257C_____0) for additional information.