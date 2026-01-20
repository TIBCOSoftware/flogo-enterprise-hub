# HTTP Client Authorization Connection Example


## Description

This example demonstrate how we can create and use HTTP Client Authorization connection in flogo apps to enable authorization and authentication for the Google Tasks API using Auth type OAuth 2.0.

The app basically creates new google task list and inserts a task into it. Then it updates the status of the task. Finally deletes the task list. All these operations will be done using restInvokeService activities which are configured using a HTTP Client Authorization connection named 'google-tasks'.

## Prerequisites

* You must ensure that Google Task API is enabled in your google account.
* You will need a connected web app in your google account under Credentials page from which you can get the Client Id and Client Secret. For more info, you can refer to google OAuth 2.0 usage documentation- https://developers.google.com/identity/protocols/oauth2/web-server
* Please make sure that your connected web application is configured with VS Code callback URL https://vscode.dev/redirect

## Copy App 

1. Copy the OAuth2_GoogleTask_Sample.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/CopyApp.png)

## Understanding the configuration

### The Connection
When you copy this app, you need to configure the Google Tasks connection on the Connections page. You also need to replace the Client ID with your own.

![The connection1](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/Connection1.png)

![The connection2](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/Connection2.png)

In the connection, note that,
* Authorization type is set to 'OAuth2'
* Grant type is set to 'Authorization Code' as supported by Google APIs.
* There are additional Auth URL query parameters for google service as below
'access_type=offline&prompt=consent' 
This is used to refresh your access token and to prompt user consent screen.
* There is a scope added to Create, edit, organize, and delete all your tasks which is 'https://www.googleapis.com/auth/tasks' for Google Tasks API.
* Client Authentication as 'Body' (Client id and secret will be sent in POST body request as supported by Google)

Once you login and allow access in user consent screen, a Base64 encoded access token string will get populated in Token field. This is the access token which will be send as Authorization Header while invoking the API to get the access to the API.

### The Flow and InvokeRestService activity
If you open the app, you will see there are InvokeRestService activities which are authentication enabled and using the 'google-tasks' connection.

![Sample Flow](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/Flow.png)

![Sample Activity](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/Activity.png)

You can enable/disable the Authentication by setting 'Enable Authentication' to 'True' or 'False'. For this sample, we need it to be 'True'.
If you enable the authentication, you will have to select one of the existing HTTP Client Authorization connections from the drop-down. In this sample, its 'google-tasks'.
You can explore all activities in the flow. They are designed in a way to create task list, insert a task in the task list, update the title of this task using PATCH method and finally delete the task list. 

### Run the application
Once you run this app using the VS Code extension, open the Postman app and select the GET method. Enter the URL/endpoint, then add the query parameter tasklist_path with the value users/@me/lists. Finally, click the Send button to run the request.

If you want to test the sample in the Flow tester, either you can create a new launch configuration and give the above value for query parameter 'tasklist_path' in inputs or import the attached 'google_tasks_Launch_Configuration.flogo' with this sample and start testing.

![Run Application](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/RunApplication.png)

![Sample Configuration](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/Sample%20Configuration.png)

![Sample Response](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/SampleResponse1.png)

### Note about Refresh Token
Based on the service you use, you need to look for the parameters to refresh the access token if you want to run your apps for longer duration. In this example access_type=offline is used in additional query parameters for this purpose. For other service like Salesforce, you may want to specify 'refresh_token' in the scope field.
We recommend you to create connections which are capable to refresh the access token.

## Outputs

1. Sample Response
![Sample Response](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/SampleResponse2.png)

2. Sample Logs
![Sample Logs](/samples/VSCode_Extension/images/REST/OAuth2_GoogleTask_Sample/SampleLogs.png)

## Help
Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/http-client-auth-connection.htm)for additional information.