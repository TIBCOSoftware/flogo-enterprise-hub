# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" />   Customer Health Monitoring Using TIBCO Flogo® Model Context Protocol(MCP) 

## Overview

This sample demonstrates how data from diverse sources—such as Pre-Sales, Support and Sales can be unified and leveraged through the MCP server to generate meaningful customer insights. Built with the **TIBCO Flogo® Connector for Model Context Protocol (MCP) – Developer Preview**, the application acts as an intelligent data orchestration tool, enabling AI agents to query data using natural language (NLP) without requiring any manual orchestration logic.

**This sample empowers Sales Managers, Product managers, Finance Manager and Support Managers with actionable insights to drive informed decisions and strengthen customer engagement.**

## ✨ Key Features

- 🧩 **Expose business data as MCP tools**  
  Provides access to Customer Information, ATS Customer Insights, Support Cases and Opportunities data.

- 🤖 **NLP-ready interface for AI agents**  
  Seamless integration with AI Agents like Claude Desktop or GitHub Copilot in VS Code to issue natural language queries

- 🔁 **Automatic orchestration**  
  No need to write or manage orchestration logic — **Flogo MCP Server** handles it for you

- 🗃️ **Prebuilt sample datasets**  
  Takes up the sample data created in test Salesforce Accounts, ATS Customer Sentiments Sheet and Opportunities Data from Postgres DB.


- 📊 **Supports actionable customer focused queries**, like:
    - _"Get me the list of customers who may have negative sentiments about the product?"_
    - _"Get me insights about upsell opportunities in NAM region"_
    - _"Get me list of customers with highest number of open cases"_

## 🚀 Getting Started

### Prerequisites

- TIBCO Flogo® Extension for Visual Studio Code 1.3.2 and above
- Any AI agent client capable of interacting with MCP Servers like Claude Desktop, GitHub Copilot etc


## Import the sample apps in the Workspace
Import Customer_Health_Monitor.flogo app in VS Code.

## Understanding the configuration
- Customer_Health_Monitor.flogo app is a FLOGO MCP server which will expose Accounts and Support data from Salesforce, Customer Sentiments data from Google Sheet and Opportunities data from Postgres DB as tools to AI Agents.

![Customer Health Monitor App Details](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/01-chm-app-details.png)


![Customer Health Monitor Salesforce Tool Details](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/02-chm-salesforce-flow.png)


## Run the application
- You can either run this app directly from VSCode as an executable or generate the build.zip file from **TIBCO Flogo® - App Build Command Line Interface** to deploy in a Data Plane on Tibco Platform. For more information on how to generate local build , Please refer [TIBCO Flogo® - App Build Command Line Interface](https://docs.tibco.com/pub/flogo/2.25.8/doc/html/Default.htm#flogo-all/flogo-base-commands.htm?Highlight=build%20cli)

    *Note: In this example, the application is running as a VSCode app executable.*

- To run the app locally as an executable, build the **Customer_Health_Monitor.flogo** app from VS Code and run the generated executable. This will start the MCP Server on port 8080.

![MCP local binary start ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/03-chm-startbinary.png)

- Configure the MCP Server URL (`http://localhost:8080/mcp`) in Claude Desktop or GitHub Copilot in VS Code. You can then send queries in natural language and receive responses as shown below.

  *In this example, We are using Claude Desktop as AI Agent.*

## Different Queries Example
- As a stake holder/Executive/Finance Manager You may send a query like "Get me detail of customers with Highest contract value in graphical format" and you will get the result in AI Agent as shown below.

![Query-01 ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/04-chm-query01.png)




- As a Sales Manager , You may send a query like "Get me list of customers in a table which are due for renewal and have open cases.


![Query-02 ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/05-chm-query02.png)




- You may also shoot up a query like "Give me insights about any upsell opportunities in a table format"


![Query-03 ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/06-chm-query03.png)




- As a Support Manager or as a Product Manager, You may want details about the active number of cases against each product, so you may send a query like "Get me the list of software products with active number of cases in a table"


![Query-04 ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/06-chm-query04.png)



**If you observe, the MCP server retrieves relevant information by calling multiple tools and combining their results to generate actionable insights**


## 🎬 Demo Video

### Complete Demo Walkthrough

[![Customer Health Monitor Demo](https://github.com/tp-devhub-hackathon-2025/user-assets-hackathon/blob/main/screenshots/customer-health-monitor/arch.png)](https://youtu.be/pNZthAn1kII)


> **Note:** In order to run the query in Claude Desktop, you will need to configure MCP Server url in > claude_desktop_config.json like below -

```
 {
  "mcpServers": {
    "FLOGO:CustomerHealthMonitor": {
      "command": "npx",
      "args": ["mcp-remote", "http://localhost:8080/mcp"]
    }
  }
 }
```

> You would also need to install npm and mcp-remote package in order for Claude Desktop to connect to MCP server.
