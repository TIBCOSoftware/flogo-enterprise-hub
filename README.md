# **Hub for TIBCO Flogo® Enterprise**

Welcome to the **Hub for TIBCO Flogo® Enterprise** — your community-driven space for sharing FLOGO samples, demos, and custom contributions for TIBCO Flogo® Enterprise.

TIBCO Flogo® Enterprise is a commercially supported offering that helps you build ultralight microservices for any application development use case — whether on-premises, in private or public clouds (including services like AWS Lambda), or on edge devices.

For more information, please refer [documentation](https://docs.tibco.com/products/tibco-flogo-enterprise-latest)

If you have purchased commercial support for TIBCO Flogo® Enterprise, please create a Service Request using your TIBCO Support credentials at [https://support.tibco.com/](https://support.tibco.com/).

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
    - **API Development**
       - REST 
           - [Rest Basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/REST/Basic) :  This sample demonstrates some of the REST features present in the FLOGO ReceiveHTTPMessage trigger and InvokeRestService activity
       - gRPC
           - [all-tls](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/gRPC/all-tls) : This sample demonstrates how to configure a gRPC server with mutual TLS authentication in Flogo and how to use the app-level spec to load the proto file for defining the gRPC service methods.
       - graphQL
           - [Basic](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/API-Development/graphQL/Basic) : This sample demonstrates how to build a GraphQL server in Flogo using the GraphQL Trigger, with the schema defined via App-Level Spec support. It enables handling GraphQL queries effortlessly through a REST-like endpoint.

    - **TIBCO Flogo® Connectors**
       - **Database Connectors**
            - [Oracle Database CRUD](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/OracleDB_clusterDeployment) : This sample demonstrates how to create and use Oracle Database Call stored procedure and CRUD activities.
            - [Oracle DB Container Deployment](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/OracleDatabase) : This sample demonstrates how to deploy and run Flogo Oracle DB app in Docker container and local kubernetes cluster using minikube. Flogo Oracle DB app need runtime oracle client libraries to run app. In the attached Docker file, we are installing the runtime dependencies for Flogo Oracle DB app.
            - [PostgreSQL Basic CRUD](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Databases/PostgreSQL-CRUD) : This sample demonstrate how to create and use PostgreSQL CRUD activities with TLS/SSL Authentication. PostgreSQL CRUD app bascially contains 4 activities. The main purpose of these activities are to insert data, update the data, delete the data and then finally perform query to fetch data from PostgreSQL database.
        - **Messaging Connectors**
            - **Enterprise Messaging Service**
                - [Request-Reply](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/VSCode_Extension/Connectors/Messaging/EMS/RequestReply): This sample illustrates a basic workflow demonstrating how EMS (Enterprise Message Service) provides activities and triggers for sending and receiving messages. You can establish a connection to your EMS broker using Transport Layer Security (TLS). The configuration includes setting up triggers to subscribe to messages published to queues and topics.

- **Samples for [Flogo Capability on TIBCO® Control Plane](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Tibco_Control_Plane)**
    - **Application Deployment**
        - [Deploy and Run Custom App Image for Flogo Oracle DB Application](https://github.com/TIBCOSoftware/flogo-enterprise-hub/tree/master/samples/Tibco_Control_Plane/App_Deployment/Custom_App_Image) : This sample demonstrates how to create Flogo application build with all dependencies preinstalled outside TIBCO Platform by using custom Docker images.
 

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
