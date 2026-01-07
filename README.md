# **Hub for TIBCO Flogo®**

Welcome to the **Hub for TIBCO Flogo®** — your community-driven space for sharing FLOGO samples, demos, and custom contributions for TIBCO Flogo®.
TIBCO Flogo® (formerly known as TIBCO Flogo® Enterprise) enables AI orchestration and intelligent automation through a visual flow designer integrated into Visual Studio Code. Built on a high-performance Go (Golang) engine, it delivers superior runtime efficiency, an ultra-light memory footprint, fast startup, and low-latency processing across edge, cloud, serverless, and on-premises environments. With its AI-ready architecture and powerful set of connectors, Flogo® transforms enterprise data into intelligent, event-driven, AI-ready workflows.
For more information, please refer [documentation](https://docs.tibco.com/products/tibco-flogo-latest)
If you have purchased commercial support for TIBCO Flogo®, please create a Service Request using your TIBCO Support credentials at [https://support.tibco.com/](https://support.tibco.com/).

---

## **TIBCO Flogo® Extension for Visual Studio Code**

The TIBCO Flogo® Extension for Visual Studio Code helps you design, build, and test Flogo® applications locally within VS Code. Take advantage of the full Visual Studio Code ecosystem, then deploy your apps anywhere — on-premises, in private or public clouds, or on edge devices.
For more information, please refer [documentation](https://docs.tibco.com/products/tibco-flogo-extension-for-visual-studio-code-latest)

---

## **About this Repository**

This repository contains docs, samples, and tools to help you build Flogo® applications and extensions for Visual Studio Code. Here’s how you can help:
- Try out the [samples](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension) provided here.
- Contribute new samples,activities, demos, or projects to help the community.

---

## **Product Samples**

Try out the Flogo application samples that help you build and deploy Flogo® applications for Visual Studio Code and Tibco Control Plane.  
- **Samples for [TIBCO Flogo® Extension for Visual Studio Code](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension)**
    - **Model Context Protocol(MCP)**<img width="30" height="30" alt="image" src="https://github.com/user-attachments/assets/7eb4d12a-e825-4356-993f-91659da1d57a" />
         - [Customer 360](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Model_Context_Protocol(MCP)/Customer360) : This sample demonstrates how to use FLOGO MCP Connector and expose your customers, products, sales data as MCP server tools and query using natural language from AI Agent.

    - **API Development**
       - **REST** 
           - [Rest Basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/REST/Basic) :  This sample demonstrates some of the REST features present in the FLOGO ReceiveHTTPMessage trigger and InvokeRestService activity
       - **gRPC**
           - [all-tls](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/gRPC/all-tls) : This sample demonstrates how to configure a gRPC server with mutual TLS authentication in Flogo and how to use the app-level spec to load the proto file for defining the gRPC service methods.
       - **graphQL**
           - [Basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/graphQL/Basic) : This sample demonstrates how to build a GraphQL server in Flogo using the GraphQL Trigger, with the schema defined via App-Level Spec support. It enables handling GraphQL queries effortlessly through a REST-like endpoint.

    - **Connectors**
       - **Azure**
           - [AzureDataFactory](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Azure/AzureDataFactory) :  This sample demonstrates how to create and use the AzureDataFactory activity in Azure Data Factory (ADF), a cloud-based data integration and orchestration service.
       - **Database Connectors**
            - [Oracle Database CRUD](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/OracleDB_clusterDeployment) : This sample demonstrates how to create and use Oracle Database Call stored procedure and CRUD activities.
            - [Oracle DB Container Deployment](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/OracleDatabase) : This sample demonstrates how to deploy and run Flogo Oracle DB app in Docker container and local kubernetes cluster using minikube. Flogo Oracle DB app need runtime oracle client libraries to run app. In the attached Docker file, we are installing the runtime dependencies for Flogo Oracle DB app.
            - [PostgreSQL Basic CRUD](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/PostgreSQL-CRUD) : This sample demonstrate how to create and use PostgreSQL CRUD activities with TLS/SSL Authentication. PostgreSQL CRUD app bascially contains 4 activities. The main purpose of these activities are to insert data, update the data, delete the data and then finally perform query to fetch data from PostgreSQL database.
        - **Messaging Connectors**
           - **Enterprise Messaging Service**
                - [Request-Reply](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Messaging/EMS/RequestReply): This sample illustrates a basic workflow demonstrating how EMS (Enterprise Message Service) provides activities and triggers for sending and receiving messages. You can establish a connection to your EMS broker using Transport Layer Security (TLS). The configuration includes setting up triggers to subscribe to messages published to queues and topics.
        - **SAP_Connectors**
           - [SAPS4HANA](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/SAP_Connectors/SAPS4HANA) : This sample demonstrates about the configuring and using the CRUD activities in the SAP S/4HANA connector.

    - **Flow design concepts**
       - **hello-world**
           - [hello-world](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Flow-design-concepts/hello-world) : This sample demonstrates a simple Flogo app that prints and returns a greeting based on the input you provide.
       - **appHooks**
           - [appHooks](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Flow-design-concepts/appHooks) :  This sample demonstrates the features present in the Flogo application used before and after the ReceiveHTTPMessage trigger.
       - **branching-errorhandling**
           - [branching-errorhandling](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Flow-design-concepts/branching-errorhandling) : This sample demonstrates how to handle branch-level error handling of null, empty, and invalid JSON objects within condition paths.
        - **shared-data**
           - [shared-data](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Flow-design-concepts/shared-data) : This sample demonstrates the SharedData activity, which enables sharing runtime data within a flow or across flows in a Flogo app.
        - **subflow-basic**
           - [subflow-basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Flow-design-concepts/subflow-basic) : This sample demonstrates how we can call simple subflows and detached invocation subflows using the Subflow activity.
 
    - **Mapping-Arrays**
       - **if-else** 
           - [if-else](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Mapping-Arrays/if-else) :  This sample demonstrates conditional data mappings using if-else blocks, with an app containing two flows and a subflow.

   - **Unit-Testing**
       - **Play Testcase - flow debugger** 
           - [Play Testcase flow debugger](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Unit-Testing/PlayTestcase-flowDebugger) :  This sample demonstrates unit testing for Flogo app flows using play mode feature, where you can test/debug the activities inside the each flow looking at its input and output data , and detect errors at the flow or activity level without building the app.
       - **Unit Testing**
           - [Unit Testing basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Unit-Testing/UnitTesting-basic) : This sample demonstrates that unit testing is a technique where individual components or flows of an application are tested in isolation to verify they work as intended and catch issues early.

- **Samples for [Flogo Capability on TIBCO® Control Plane](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Tibco_Control_Plane)**
    - **Application Deployment**
        - [Deploy and Run Custom App Image for Flogo Oracle DB Application](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Tibco_Control_Plane/App_Deployment/Custom_App_Image) : This sample demonstrates how to create Flogo application build with all dependencies preinstalled outside TIBCO Platform by using custom Docker images
        - [Active Space]( https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Tibco_Control_Plane/App_Deployment/Custom_App_Image/ActiveSpaces) : This sample demonstrates how to deploy a TIBCO Flogo® ActiveSpaces application using a custom Docker image in TIBCO Control Plane.The Flogo ActiveSpaces application requires ActiveSpaces runtime libraries to connect to an ActiveSpaces cluster and perform data operations.The provided Dockerfile installs all required ActiveSpaces runtime dependencies needed to successfully run the Flogo ActiveSpaces application.

---

## **Contributing**

We welcome contributions! To contribute:
- Fork this repository.
- Make your changes.
- Submit a pull request (PR).

Our maintainers will review your PR and may request changes before merging. For any questions, please reach out to [integration-pm@tibco.com](mailto:integration-pm@tibco.com).

---

## **Feedback**

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

## **License**

Copyright 2025 Cloud Software Group, Inc.
This project is Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0 Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.

---

Thank you for being part of the Flogo® community!
