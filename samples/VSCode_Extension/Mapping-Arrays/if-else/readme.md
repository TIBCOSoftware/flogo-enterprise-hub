# Conditional Mappings Sample- if/else

## Description

This sample demonstrates an example of conditional data mappings using if-else blocks. The app contains two flows and a subflow. The subflow post the shopping order details using InvokeRestService activity and returns the created object containing shopping order details. The two flows are used to display these order details based on the following conditions-
1. if the order status is delivered or completed then display the feedback link to user otherwise feedback link should not be displayed in the output
2. if the input JSON (POST body) does not contain item array then we do not want to display certain attributes or json tags in the output (remove null value for the non-existing JSON keys)

## Copy App

1. Copy the conditional_mappings_ifelse.flogo app into your workspace.

![Copy App](../../images/mapping-arrays/CopyApp.png)


2. Click on conditional_mappings_ifelse.flogo. On the app-details page of conditional_mappings_ifelse.flogo, you can see the display_orderDetails and removeJsonAttributes_orderDetails flows; post_orderDetails is a subflow. When you click on either flow, the subflow post_orderDetails is invoked inside the flow. After that activity, a Mapper activity, a LogMessage activity, and a Return Activity are connected to each other in sequence.

![App Details Page](../../images/mapping-arrays/AppDetailsPage.png)

![Trigger & Activity First Flow](../../images/mapping-arrays/Trigger&ActivityFirstFlow.png)

![Trigger & Activity Second Flow](../../images/mapping-arrays/Trigger&ActivitySecondFlow.png)


## Understanding the configuration

* The app has two flows and one subflow. The subflow 'post_orderDetails' contains a invokeRestService activity to POST order details and returns the created data.
* The flow display_orderDetails calls this subflow to create an order with order details. To achieve the first objective of displaying feedback link based on the order status, we have added a condition on ShoppingCartOrder object using kebab menu in its input field in a mapper activity.   
The if condition is defined as '$activity[call_postOrderDetails].ShoppingCartOrder.ShoppingCartOrder.Status == "delivered" || $activity[call_postOrderDetails].ShoppingCartOrder.ShoppingCartOrder.Status == "completed"'.  
If the condition matches, we show all attributes in output json along with feedback link. To remove 'feedback' attribute in output json we do not map it in else block.


* Similarly, to achieve the second objective to remove an attribute from output which is not present in POST body, we can use isdefined() function in if condition. In second flow 'removeJsonTags_orderDetails', we are checking if item[] attribute is present in POST body using the if condition 'isdefined( $activity[call_postOrderDetails].ShoppingCartOrder.ShoppingCartOrder.Item)'. If present or defined then display all order details else do not display item[], Shipment[] and feedback attributes in the output.

![The flows](../../images/mapping-arrays/TheFlows.png)

![If Condition First Flow](../../images/mapping-arrays/FirstFlowIfCondition.png)

![Else Block Mappings First Flow](../../images/mapping-arrays/FirstFlowElseCondition.png)

![If Conditions Second Flow](../../images/mapping-arrays/SecondFlowIfCondition.png)


* We might think of ternary operator to achieve this but that would end up setting null or empty value "". So Feedback cannot be removed from output using this approach. It would show null or "".  
For example, $activity[call_postOrderDetails].ShoppingCartOrder.ShoppingCartOrder.Status == "delivered" ?  $activity[call_postOrderDetails].ShoppingCartOrder.ShoppingCartOrder.Feedback : null

## Run the application

Once you are ready to run the application, you can use run option and then run this app.
Once it reaches to Running state, go to API tester and hit tryout the first endpoint. You can use below input JSON (Note that Status is 'pending'. You can also try with 'delivered' or 'completed'):

* {
  "ShoppingCartOrder": {
    "Order": "D01-8127020-6200600",
    "PlacedOn": "2017-10-21",
    "Feedback": "https://3err.bitly.com/feed",
    "Status": "pending",
    "Item": [
      {
        "Description": "A Product for Everyone",
        "Code": "D01-8127020-6200600-1-1",
        "Price": 13.69,
        "Quantity": 1
      }
    ],
    "Shipment": [
      {
        "Arriving": "2017-10-23",
        "DeliveryAddress": {
          "City": "Swindon",
          "County": "Wiltshire",
          "Line1": "76 Godwin Road",
          "Line2": "Stratton",
          "PostCode": "SN34XG"
        }
      }
    ]
  }
}

![POST Body API Tester First Flow](../../images/mapping-arrays/PostBodyFirstFlow.png)


For second endpoint, you can use the below input JSON (Note that there is no Item[]):

* {
  "ShoppingCartOrder": {
    "Order": "D01-8127020-6200600",
    "PlacedOn": "2017-10-21",
    "Feedback": "https://3err.bitly.com/feed",
    "Status": "delivered",
    "Shipment": [
      {
        "Arriving": "2017-10-23",
        "DeliveryAddress": {
          "City": "Swindon",
          "County": "Wiltshire",
          "Line1": "76 Godwin Road",
          "Line2": "Stratton",
          "PostCode": "SN34XG"
        }
      }
    ]
  }
}

![POST Body API Tester Second Flow](../../images/mapping-arrays/PostBodySecondFlow.png)


## Outputs

1. Output of first flow:

![Output Logs First Flow](../../images/mapping-arrays/FirstFlowLogs.png)


2. Endpoint Response for second flow

![Endpoint Response Second Flow](../../images/mapping-arrays/EndpointResponseforSecondflow.png)


3. Application Logs for second flow

![Output Logs Second Flow](../../images/mapping-arrays/LogsOfSecondFlow.png)


## Help

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all-vsc/conditional-mapping.htm?TocPath=User%2520Guide%257CApp%2520Development%257CData%2520Mappings%257C_____8) for additional information.
