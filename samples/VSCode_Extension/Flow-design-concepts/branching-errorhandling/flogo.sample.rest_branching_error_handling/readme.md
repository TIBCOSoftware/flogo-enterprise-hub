# Branching - Error Handling Sample

## Understanding the configuration

The app has two flows. Both flows contain an InvokeRESTService activity and a Return activity, with a REST trigger to get books and get books by ISBN. Both flows use the same REST trigger.

The REST trigger listens on port 9999. Based on the incoming request path, it invokes either the getBooks or getBooksByISBN flow.

* getBooks Flow : This flow calls a REST backend using an InvokeRESTService activity to fetch all books. Finally, the flow returns the JSON result to the REST caller using a Return activity.

* getBooksByISBN Flow : This flow invokes the backend via InvokeRESTService to get a book by ISBN. Based on the response or input validation, the flow branches as follows:

Success : If the ISBN is valid and the book is found, it returns a successful response. The JSON book data is returned to the caller using: utility.renderJSON($activity[InvokeRESTService1].responseBody, boolean.false()).

Success with Condition : If the response body is empty (string.equals(string.tostring($activity[InvokeRESTService1].responseBody), "[]")), it calls the Log Message activity to log the message
"No Book found with the given ISBN Number", and returns the same message as the response.

Success with Condition : If the ISBN is invalid (string.regex("[^0-9]", $flow.isbn)), it calls the Log Message activity and logs "********** Invalid ISBN Number ********". After that, it triggers the Throw Error activity and returns an Invalid ISBN Number response.

Every flow ends with a Return activity to ensure correct termination and that a response is sent back to the REST trigger.

**This sample application is based on the BookStore example. It uses a backend REST API that returns sample JSON data. The backend REST API is hosted at:**
(https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book)

**First, you need to upload the Throw Error Extension from:** (https://github.com/TIBCOSoftware/flogo-contrib/tree/master/activity/error)

**If you run any of these samples locally using TIBCO Flogo® Enterprise:**

**1. To get all books, hit the URL:** http://localhost:9999/books

**2. To get a book by ISBN, hit the URL:** http://localhost:9999/books/1451648537

**3. To test the error handler, hit the above URL with an invalid ISBN number, for example:**
http://localhost:9999/books/999

**4. You can check the sample JSON data for valid ISBNs to use while testing the samples at:**
https://my-json-server.typicode.com/tibcosoftware/tci-flogo/Book

## Copy App 

**1.** Copy the flogo.sample.rest_branching_error_handling.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/Copy_App.png)

**2.** Click on the flogo.sample.rest_branching_error_handling.flogo app.On the app details page, you can see the getBooks and getBooksByISBN flows.Click the getBooks flow. You will see the REST trigger connected to an InvokeRestActivity, and the InvokeRestActivity connected to a Return activity.

Then click the InvokeRestActivity. You will see a Configuration tab. Inside the Configuration tab, the following options are displayed: Settings, InputSettings, Input, OutputSettings, Output, Loop, and Retry on Error.Configure all the required details in the InvokeRestActivity.

![Get Books](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/Flow.png)

![Trigger & Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/Trigger&Activity.png)

![InvokeRest Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/InvokeRestActivity1.png)

**3.** Next, click the Return activity.You will see a Configuration tab. Inside the Configuration tab, the Map Outputs option is displayed. Configure all the required details in the Return activity.

![Return Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ReturnActivity1.png)

**4.** Click again on the flogo.sample.rest_branching_error_handling.flogo app.On the app details page, click the getBooksByISBN flow.You will see the REST trigger connected to an InvokeRestActivity. The InvokeRestActivity has three branches.

![Get Book By ISBN](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/GetBookByISBN1.png)

![Trigger & Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/Trigger&Activity2.png)

**i.** success branch : This branch is connected to a Return1 activity.Click the Return activity. You will see a Configuration tab. Inside the Configuration tab, the Map Outputs option is displayed.
Configure all the required details in the Return activity.

![Success Branch](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/SuccessBranch.png)

![Return Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ReturnActivity2.png)

**ii.** This branch is connected to a Log Message activity.Click the Log Message activity. You will see a Configuration tab. Inside the Configuration tab, the Settings, Input, and Loop options are displayed.Configure all the required details in the Log Message activity.

The Log Message activity is connected to a Return2 activity.Click the Return activity and configure the required details in the Map Outputs section.

![Success with condition Branch 1](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/SuccessWithCondition1.png)

![Log Message 1 Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/LogMessage1.png)

![Return Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ReturnActivity3.png)

**iii.** success with condition branch : This branch is connected to a Log Message1 activity.Click the Log Message1 activity. You will see a Configuration tab. Inside the Configuration tab, the Settings, Input, and Loop options are displayed.Configure all the required details in the Log Message1 activity.

The Log Message activity is connected to a Throw Error activity.Click the Throw Error activity. You will see a Configuration tab. Inside the Configuration tab, the Input and Loop options are displayed.Configure all the required details in the Throw Error activity.

![Success with condition Branch 2](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/SuccessWithCondition2.png)

![Log Message 2 Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/LogMessage2.png)

![Throw Error Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ThrowError.png)

**In this flow, errors are handled in two ways:**

**1.** Using the Throw Error Activity in the getBooksByISBN flow
By using the Throw Error activity, we get the "********** Invalid ISBN Number ********" message.
Refer to the image above for details.

**2.** Using the Error Handler flow in the getBooksByISBN flow
Click on the Error Handler. In the Error Handler flow, a Log Message activity is used. The error message is set to "******** In Error Handler ********". 

In the Return activity, the response is passed as: string.concat($error.activity, " ", $error.message).

![Error Handler Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ErrorHandlerFlow.png)

![Log Message 3 Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/logMessage3.png)

![Return 4 Activity](/samples/VSCode_Extension/images/flow-design-concepts/Branching-errorhandling/flogo.sample.rest_branching_error_handling/ReturnActivity4.png)

## Help

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/creating-a-flow-exec.htm?TocPath=User%2520Guide%257CApp%2520Development%257CCreating%2520Flows%2520and%2520Triggers%257CFlows%257CCreating%2520a%2520Flow%2520Execution%2520Branch%257C_____0) for additional information.