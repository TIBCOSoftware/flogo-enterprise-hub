## Hello World Sample

## Copy App 


1. Copy the HelloWorld.flogo app into your workspace.

![Copy App](../../images/flow-design-concepts/hello-world/CopyApp.png)


2. Click on the HelloWorld.flogo app. On the app details page, you can see the sayHello flow. Click the sayHello flow — you’ll see the REST trigger connected to a LogmessageActivity, which in turn is connected to a ReturnActivity. Then click LogmessageActivity — you will see a Configuration tab. Inside the Configuration tab, you will find Settings, Input, and Output sections displayed.

![say Hello](../../images/flow-design-concepts/hello-world/sayHello.png)

![Trigger & Activity](../../images/flow-design-concepts/hello-world/Trigger&Activities.png)

![Log message Activity](../../images/flow-design-concepts/hello-world/LogMessageActivity.png)


## Understanding the configuration

This sample is a simple Flogo app that prints and returns a greeting based on the input you provide. It uses an HTTP trigger to receive an HTTP message with the following parameters:

Port: 9999
Method: GET
Resource path: /hello/{name}

![HTTP trigger configuration 1](../../images/flow-design-concepts/hello-world/Trigger1.png)

![HTTP trigger configuration 2](../../images/flow-design-concepts/hello-world/Trigger2.png)

![HTTP trigger configuration 3](../../images/flow-design-concepts/hello-world/Trigger3.png)

![HTTP trigger configuration 4](../../images/flow-design-concepts/hello-world/Trigger4.png)

The trigger in this sample retrieves the value of the path parameter name, which is passed to the activities of the flow named sayHello. This flow includes two activities:

1. Log activity: it prints `Name: {name}` in the logs, e.g., `Name: world` if you entered 'world' as a path parameter.

![Log activity configuration 1](../../images/flow-design-concepts/hello-world/Log1.png)

2. Return activity: it returns a JSON object `{ "message": "Hello world" }` if you entered 'world' as a path parameter.

![Return activity configuration 1](../../images/flow-design-concepts/hello-world/Return1.png)

## Help 

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#flogo-all/creating-your-first-.htm?TocPath=User%2520Guide%257CIntroduction%257C_____2) for additional information.