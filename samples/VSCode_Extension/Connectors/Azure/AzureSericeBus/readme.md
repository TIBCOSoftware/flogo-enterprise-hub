# AzureServiceBus Sample


## Description

This example demonstrates how to publish different types of messages to Azure Service Bus queues and topics, and how to receive and log messages using queue and topic subscribers.

The flow in the AzureServicebusSample app basically publish different types of messages over a queue and topic entities.The AzureServiceBus Queues are sent to and received messages from queues. The AzueServiceBus Topic subscribers will be used in publish-subscriber scenario. The example having multiple trigger handlers using AzureServcieBus trigger(Queue Receiver and Topic Subscriber) .

## Prerequisites

 1. Ensure that you have access of Azure portal.
 2. To Create and execute the AzureServiceBus app we require any one of the following  authentication type    
  a.Authentication type 'OAuth2' -  'ServiceBusNameSpace,TenantId,ClientId,ClientSecret'.
  b.Authentication type as'SAS Token'-'ServiceBusNameSpace,Authorization Rule Name, SharedAccessKey' from the Azure portal.

## Import sample into VSCode Workspace

1. Download the sample flogo file i.e 'AzureServicebusSample.flogo'
2. Place the downloaded file into your Visual Studio Code workspace.
3. Open the file by clicking on it in VSCode.


## Understanding the configuration

### The Connection

![The Connection](../../../images/Azure/AzureServiceBus/connectiondetails.png)

In the connection, note that:

1.Connection Name- In this field we give the connection name.  
2.Auth Mode- Select either 'SAS Token' or 'OAuth2'.  
3.Service Bus Namespace-In this field, we need to provide the Service Bus Namespace.   
4.Authorization Rule Name -In this field, we need to provide the Authorization Rule Name.  
5.SharedAccessKey-In this field, we need to provide the SharedAccessKey.  
6.Retry Count-The maximum number of times to retries to establish a connection.  
7.Retry Interval - The time interval in(ms) between each retry attempt.

### The Flow and InvokeRestService activity
If you open the app, you will see there are three flows, one is Publisher for Queues and Topics and other two is like consumer i.e QueueReceiver and TopicSubscriber
![The Flows](../../../images/Azure/AzureServiceBus/flows.png)

The 'Publisher' flow in the AzureServicebusSample app basically sends a messages over Queues and Topics. It has two publish activities for Queue and Topic respectively.All these operation will be done when execute the REST trigger with valid input schema provided in ReceiveHTTPMessage trigger. REST trigger have method POST.
![The AzureServicebusSample Flows](../../../images/Azure/AzureServiceBus/publisherflow.png)

When 'Publisher' flow sends a message through a Queue, then the Queue Receiver trigger receives the message from the respective queue. To see how Will Queue Receivers work, see Azure Service Bus documentation.
![The AzureServicebusSample Flows](../../../images/Azure/AzureServiceBus/queuereceiverflow.png)

When 'Publisher' flow sends a message through a Topic, then the Topic Subscriber trigger receives the message from the topic of the respective subscriber. To see how Will Queue Receiver works, see Azure Service Bus documentation.
![The AzureServicebusSample Flows](../../../images/Azure/AzureServiceBus/topicsubscriberflow.png)



### Run the application
For running the application, 
1. Start by adding a local runtime in Visual Studio Code. Assign a name to the runtime and click the "Save" button.

![Add Local Runtime](../../../images/Azure/AzureServiceBus/Runtime.png)

2. Select the local runtime you added for your Flogo Azureservicebus app. To do this, click on the FLOGO APP in the explorer, then click "Actions" and select the added Local Runtime.
![Select Runtime](../../../images/Azure/AzureServiceBus/Select_Local_Runtime.png)

3. Now Build your Flogo Azureservicebus app. In the FLOGO APP section, click on "Build,".
![Build Application](../../../images/Azure/AzureServiceBus/App_Build.png)

4. Once build is successful you can see the binary in bin folder.

![Build Application](../../../images/Azure/AzureServiceBus/Binary_file_generated.png)

5. Now Run the Azureservicebus app. 
![Run Application](../../../images/Azure/AzureServiceBus/Run_application.png).

6.Now Open Postman and select the method as 'POST',pass request body and url then click on 'Send' button.

![Run Application](../../../images/Azure/AzureServiceBus/Run_application_using_Postman.png).

7.After click on 'Send' button see the results.

## Outputs

1. Sample Response when click on 'Send' button

![Sample Response](../../../images/Azure/AzureServiceBus/Response_in_Postman.png)

2. Sample Logs in VS Code
![Sample Logs](../../../images/Azure/AzureServiceBus/Output_in_VScode.png)





