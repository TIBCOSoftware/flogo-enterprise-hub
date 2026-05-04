# Salesforce activities sample for bulk operations


## Description

This example demonstrates how to create a job for a bulk query operation and check the status of the Job ID created earlier in the flow. It also retrieves the results of the bulk query job with a specific number of result sets and a maximum number of records fetched per result set by applying a loop to the subflow.
The Salesforce_BulkAPISample app example includes bulk job activities from the Salesforce.com category and uses a Salesforce.com connection.

## Prerequisites

* Ensure that Flogo Connector for Salesforce.com must be installed.
* Ensure that you have an active Salesforce.com account.
* Ensure that you have set up the OAuth permissions in Salesforce.com which will be used in the Salesforce connection for Client ID and Client Secret parameters. To set up OAuth permissions, follow the steps mentioned in 'Creating a Salesforce.com Connection' topic in the TIBCO Flogo® Extension for Visual Studio Code documentation.

## Copy App 

1. Copy the Salesforce_BulkAPISample.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/CopyApp.png)

## Understanding the configuration

### The Connection
When you Copy this app, you need to configure the 'Salesforce' connection in Connections page. It has pre-filled values except Client Secret. You also need to change Client Id with yours.

![The connection](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Connection1.png)

Note: After imported an app, in the imported connection under Connection tab,
* Client ID has prefilled value which is the Consumer Key in the Salesforce Account (get it from the Connected Apps section in Salesforce Account).
* Client secret is blank and you have to provide the Consumer Secret in the Salesforce Account (get it from the Connected Apps section in Salesforce Account).
* For both Client ID and Client Secret values ensure that you have set up the OAuth permissions in Salesforce.com. 

Once you provide both the values then login to your salesforce account and allow access in user consent screen, a Base64 encoded access token string will get populated in OAuth2 Token field. This is the access token which will be send as Authorization Header while invoking the API to get the access to the API.

![The connection](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Connection2.png)

### The Flow and Salesforce activities
If you open the app, you will see that there are two flows in the Salesforce_BulkAPISample app: the main flow, MainFlowWithSFCreateCheckStatusJob, and the sub flow, SubFlowWithSFGetQueryJob.

![The Flows](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Flow.png)

The flow MainFlowWithSFCreateCheckStatusJob basically creates a new job for a bulk query using the SalesforceCreateJob activity to efficiently query large data sets for the Account object in Salesforce. It then checks the status of the Job ID created by the preceding SalesforceCreateJob activity using the SalesforceCheckJobStatus activity. To retrieve the results of the bulk query job, the SalesforceGetQueryJobResult activity must be used inside a subflow, and the subflow must be placed inside a loop. To start this flow, use a REST trigger with the GET method and the path parameter bulk, in which you can pass any string-type value.

![The Main Flow](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/MainFlow.png)

The flow SubFlowWithSFGetQueryJob contains the SalesforceGetQueryJobResult activity, which retrieves records from the query job in specific batches based on the locator value. As a result, you will receive all the records fetched by the query defined in the SalesforceCreateJob activity in the main flow, in a paginated format.

![The Sub Flow](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/SubFlow.png)

### Run the application
Once you are ready to run the application, use the Run option to start the app.

![Run App 1](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Run1.png)

Once you run this app using the VS Code extension, open the Postman app and select the GET method. Enter the URL/endpoint (http://localhost:9999/salesforce/trybulk). You will have to pass value for the path parameter 'bulk'. You can provide any string type value for 'bulk' parameter and then click the Send button to run the request.

![Run App 2](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Run2.png)

## Outputs

1. Sample Response when hit the endpoints
![Sample Response](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Response.png)

2. Sample Logs
![Sample Log 1](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Log1.png)

![Sample Log 2](/samples/VSCode_Extension/images/CRM/Salesforce/Salesforce_BulkAPISample/Log2.png)

## Help
Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#connectors/salesforce/salesforcecreatejob.htm?TocPath=Supported%2520Flogo%2520Connectors%257CSalesforce.com%257C_____8) for additional information.
