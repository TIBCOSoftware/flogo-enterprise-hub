# Redis Sample on creating connection and performing various commands of Group SETS


## Description

This example demonstrates how we can create a Redis connection and perform various commands of the Redis Sets group.
The Flogo Redis app contains a single activity: Redis Command. In this activity, we have five groups (Hashes, Lists, Sets, SortedSets, and Strings) and their respective commands which perform operations on the Redis database. 

## Prerequisites

1. Make sure Redis database is up and running on AWS EC2 instance/ local machine.
2. You need to make sure that your public ip is whitelisted (If you are using database hosted on AWS EC2 instance).
 
## Copy App

1. Copy the Redis-Sets-App.flogo app into your workspace.

![Copy App](/samples/VSCode_Extension/images/Redis/CopyApp.png)

## Understanding the configuration

### The Connection

![The connection 1](/samples/VSCode_Extension/images/Redis/Connection1.png)

![The connection 2](/samples/VSCode_Extension/images/Redis/Connection2.png)

In the connection, note that,
1. Host - In this field we give public DNS of EC2 instance on which database is hosted.
2. Port - Port number on which redis server is running.
3. Default Database Index - It is the default index at which database is stored.
4. Username – Used to connect to the Redis database.
5. Password – Password for authenticating the connection with the Redis server.
6. Secure Connection – If Secure connection is true, then it is mandatory to provide the PEM-encoded file of the client certificate and client key for client authentication, and the PEM-encoded file of the CA certificate or server certificate for server authentication.

### The Flow

If you go inside the app, you can see in flow we have created multiple activities which indicate different commands of Redis Group Sets that perform some operations. Below is the description of each activity having different commands:

1. Activity having Command "SADD" - This is used to add single/multiple members to set stored at key.

2. Activity having command "SMEMBERS" - Returns all the members of the set stored at key.

3. Activity having command "SISMEMBER" - Check whether element is member of the set or not.

4. Activity having command "SCARD" - Returns the set cardinality (number of elements) of the set stored at key.

5. Activity having command "SREM" - Remove the specified member(s) from the set stored at key.

6. Activity having command "SPOP" - Removes and returns one or more random members from the set stored at key.

7. Activity having command "SMOVE" - Move member from the set at source to the set at destination.

![Sample Response 1](/samples/VSCode_Extension/images/Redis/SampleResponse1.png)

![Sample Response 2](/samples/VSCode_Extension/images/Redis/SampleResponse2.png)

Redis Command Activity has different tabs below are the description:

Settings tab - In this we need to select connection name, Group and respective command.

Input tab - Input tab fields change according to Group and command selection. Generally in this tab we pass Key name and its value (Value can be array or string).
If we pass DatabaseIndex value in activity then it means that this Redis Database partition select during run-time (DatabaseIndex value is optional here).

Also in flow we have Log Message and Return Activity for getting the output.

![Sample Response 3](/samples/VSCode_Extension/images/Redis/SampleResponse3.png)

![Sample Response 4](/samples/VSCode_Extension/images/Redis/SampleResponse4.png)

### Run the application

Once you are ready to run the application, use the Run option to start the app.

![Sample Response 5](/samples/VSCode_Extension/images/Redis/SampleResponse5.png)

Once you run this app using the VS Code extension, open the Postman app and select the GET method. Enter the URL/endpoint and then click the Send button to run the request.

![Sample Response 6](/samples/VSCode_Extension/images/Redis/SampleResponse6.png)

## Outputs

1. Output of Redis-Sets-App.flogo app:

![Output 1](/samples/VSCode_Extension/images/Redis/Output1.png)

2. Logs of Redis-Sets-App.flogo app:

![Output 2](/samples/VSCode_Extension/images/Redis/Output2.png)

## Help

Please visit our [TIBCO Flogo<sup>&trade;</sup> Extension for Visual Studio Code documentation](https://docs.tibco.com/pub/flogo/latest/doc/html/Default.htm#connectors/redis/overview.htm?TocPath=Connectors%2520User%2520Guide%257CSupported%2520Flogo%2520Connectors%257CRedis%257C_____0) for additional information.