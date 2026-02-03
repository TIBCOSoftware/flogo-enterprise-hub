# Salesforce Upsert on Bulk records and Salesforce Trigger With Change Data Capture Example

 
## Description

This example demonstrates how we can do the Upsert on multiple records in Salesforce using Salesforce Upsert activity in flogo. If the records in the collection have valid External Id Field Name values, the corresponding records in the database will be updated with the flow’s collection. If not, new records will be created and saved. In this example, records are fetched using query in MySQL database and those records are mapped to the Salesforce Upsert activity input and then those incoming records are either created or updated according to custom field called an external ID to determine whether to create a new record or update an existing record.

Then in the other flow, Salesforce trigger with the Subscriber type as Change data capture is getting executed once records are upserted in Salesforce. Change Data Capture publishes change events in the flogo runtime logs, which represent changes to Salesforce records. In this example changes include creation of a new record and/or updates to an existing records. So in this case when SFUpsertWithMySQLDB flow executes, the salesforce trigger will start and provide respective output in the logs.


## Prerequisites 
 
* Ensure that MySQL database must be installed either on local computer or on AWS EC2 instance. 
* You need to make sure that your public ip is whitelisted (If you are using database hosted on AWS EC2 instance).
* Ensure that you have an active Salesforce.com account.
* Ensure that you have set up the OAuth permissions in Salesforce.com which will be used in the Salesforce connection for Client ID and Client Secret parameters. To set up OAuth permissions, follow the steps mentioned in 'Creating a Salesforce.com Connection' topic in the TIBCO Flogo® Extension for Visual Studio Code documentation
* Ensure that you have already added Change Data capture in Salesforce.com. To add Change Data capture in Salesforce.com, you can refer the Salesforce.com product documentation.

## Copy App 

1. Copy the SFSubscriberTypesWithUpsertActivity.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/CopyApp.png)


## Understanding the configuration

### The Connection
When you Copy this app, you need to configure the 'Salesforce' connection in Connections page. It has pre-filled values except Client Secret. You also need to change Client Id with yours.

![The connectionImport](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Connection1.png)

Note: After imported an app, in the imported connection under Connection tab,
* Client ID has prefilled value which is the Consumer Key in the Salesforce Account (get it from the Connected Apps section in Salesforce Account).
* Client secret is blank and you have to provide the Consumer Secret in the Salesforce Account (get it from the Connected Apps section in Salesforce Account).
* For both Client ID and Client Secret values ensure that you have set up the OAuth permissions in Salesforce.com. 

Once you provide both the values then login to your salesforce account and allow access in user consent screen, a Base64 encoded access token string will get populated in OAuth2 Token field. This is the access token which will be send as Authorization Header while invoking the API to get the access to the API.

![The connectionAfterLogin](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Connection2.png)

### The Flow and Salesforce Upsert activity
If you open the app, you will see there are two flows in the SFSubscriberTypesWithUpsertActivity app. The flow 'SFUpsertWithMySQLDB' and second flow 'SFChangeDataCapture'.

![Main Flows](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/MainFlow.png)

The 'SFUpsertWithMySQLDB' flow in the SFSubscriberTypesWithUpsertActivity app, records are getting fetched from mysql database using query and then those records are mapped as an input to Salesforce Upsert activity. In the Salesforce Upsert activity those incoming records are either created or updated into the Contact object according to values mapped to the custom field called an external ID "ContactID__c". You can see those Upserted records from the SalesforceQuery activity's output after executing the flow. All these operation will be done when execute the REST trigger with Get method and path parameter used in ReceiveHTTPMessage trigger.

![The SFUsert Flows](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/SFUpsertWithMySQLDB.png)

The 'SFChangeDataCapture' flow in the SFSubscriberTypesWithUpsertActivity app have ReceiveSalesforceMessage trigger which starts whenever a changes occurs on records in the Contact object in Salesforce.com and activates the flow. So in this case when SFUpsertWithMySQLDB flow executes, the salesforce trigger will start and provide respective output in the logs.

![The SFTrigger Flows](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/SFChangeDataCapture.png)

### Run the application
Once you are ready to run the application, use the Run option to start the app.

![Run1](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Run1.png)

Once you run this app using the VS Code extension, open the Postman app and select the GET method. Enter the URL/endpoint (http://localhost:9999/sfupsert/testupsert). You will have to pass value for the path parameter 'upsert'. You can provide any string type value for 'upsert' parameter and then click the Send button to run the request.

![Run2](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Run2.png)  

## Outputs

1. Sample Response when hit the endpoints, first is the output when record is created and second is when record updated. 

![Sample ResponseForRecordsCreated](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/SampleRecordsCreated.png) 

![Sample ResponseForRecordsUpdated](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/SmpleRecordsUpdated.png) 

2. Sample Logss

![Sample Logs 1](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Log1.png) 

![Sample Logs 2](/samples/VSCode_Extension/images/CRM/Salesforce/SFSubscriberTypesWithUpsertActivity/Log2.png) 

## Help
Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo-vscode/latest/doc/html/Default.htm#connectors/salesforce/salesforceupsert.htm?Highlight=upsert%20) for additional information.