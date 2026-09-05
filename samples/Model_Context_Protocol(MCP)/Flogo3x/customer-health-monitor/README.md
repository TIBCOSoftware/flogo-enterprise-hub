# <img width="25" height="25" alt="mcp" src="https://github.com/user-attachments/assets/80bf0bb2-d116-404a-91a0-5b4f3af2e476" />   Customer Health Monitoring Using TIBCO Flogo® 3 Model Context Protocol(MCP)

## Overview

This sample demonstrates how data from diverse sources—such as Pre-Sales, Support and Sales can be unified and leveraged through the MCP server to generate meaningful customer insights. Built with the **TIBCO Flogo® 3 Connector for Model Context Protocol (MCP) – Developer Preview**, the application acts as an intelligent data orchestration tool, enabling AI agents to query data using natural language (NLP) without requiring any manual orchestration logic.

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

- TIBCO Flogo® 3 Extension for Visual Studio Code (TIBCO Flogo® 3.0.0 or later)
- Any AI agent client capable of interacting with MCP Servers like Claude Desktop, GitHub Copilot etc

## Understanding the configuration

- The **`Customer_Health_Monitor`** app is a FLOGO MCP server which will expose Accounts and Support data from **Salesforce**, Customer Sentiments data from a **Google Sheet** and Opportunities data from **Postgres DB** as tools to AI Agents.
- The app is organized as a Flogo 3 project folder (a folder containing `app.fgmd`). Each business data source is backed by a flow that is published as an MCP tool through the `MCPServer` trigger:
    - **Customer Information** (Salesforce) — `flows/Get_Customer_Info.fgflow`
    - **Support Cases** (Salesforce) — `flows/Get_Customer_Support_Cases.fgflow`
    - **ATS Customer Insights / Sentiments** (Google Sheet) — `flows/ATS_Customer_Relation_metrics.fgflow`
    - **Opportunities** (Postgres DB) — `flows/Get_New_Opportunity_Data.fgflow`
- In Flogo 3, connection configuration lives in the app's `connections/*.fgconn` files, and the referenced credentials/URLs are set through App Properties in `app.fgprops`:
    - Salesforce → `connections/customer-account-info-sf.fgconn`
    - Google Sheets → `connections/ats-tracker-gsheet.fgconn`
    - PostgreSQL → `connections/pg-new-opportunities-data.fgconn`


## App Properties

Set the following App Properties for your environment in the app's `.fgprops` file (`Customer_Health_Monitor/app.fgprops`). The values below are the defaults shipped with the sample — replace credentials and endpoints with your own.

### Salesforce (connection: `customer-account-info-sf`)

| App Property | Default / What to set |
| --- | --- |
| `Salesforce.customer-account-info-sf.Environment` | `Production` |
| `Salesforce.customer-account-info-sf.Client_Id` | Your Salesforce connected-app Client Id |
| `Salesforce.customer-account-info-sf.Client_Secret` | Your Salesforce connected-app Client Secret (stored as a secret) |
| `Salesforce.customer-account-info-sf.OAuth2_Token` | Your Salesforce OAuth2 token |

### Google Sheets (connection: `ats-tracker-gsheet`)

The Google Sheets connection authenticates with a **service account key (JSON)** that is stored directly in the connection config file `connections/ats-tracker-gsheet.fgconn` (there are no Google-specific entries in `app.fgprops`). To use your own sheet, open that connection config and replace the service account key with your own, and share the target Google Sheet with the service account's client email.

### PostgreSQL (connection: `pg-new-opportunities-data`)

| App Property | Default / What to set |
| --- | --- |
| `PostgreSQL.pg-new-opportunities-data.Host` | `ec2-54-177-39-186.us-west-1.compute.amazonaws.com` |
| `PostgreSQL.pg-new-opportunities-data.Port` | `5433` |
| `PostgreSQL.pg-new-opportunities-data.Database_Name` | `sampledb` |
| `PostgreSQL.pg-new-opportunities-data.User` | `postgres` |
| `PostgreSQL.pg-new-opportunities-data.Password` | Your PostgreSQL password (stored as a secret) |
| `PostgreSQL.pg-new-opportunities-data.Maximum_Open_Connections` | `0` |
| `PostgreSQL.pg-new-opportunities-data.Maximum_Idle_Connections` | `2` |
| `PostgreSQL.pg-new-opportunities-data.Maximum_Connection_Lifetime` | `0` |
| `PostgreSQL.pg-new-opportunities-data.Maximum_Connection_Retry_Attempts` | `3` |
| `PostgreSQL.pg-new-opportunities-data.Connection_Retry_Delay` | `5` |
| `PostgreSQL.pg-new-opportunities-data.Connection_Timeout` | `20` |

> **MCP server endpoint:** The MCP server port (`8080`), path (`/mcp`), and server name (`CustomerHealthMonitor`) are configured in the `MCPServer` trigger settings. With the defaults, the server starts on port `8080` and exposes the endpoint at `http://localhost:8080/mcp`.

## Setup & Run

1. Open this sample folder in VS Code with the TIBCO Flogo® 3 extension. It detects the Flogo 3 project(s) — each folder containing `app.fgmd`: `Customer_Health_Monitor`.
2. Open the app's `.fgprops` file and set the App Properties for your environment (see App Properties below) — Salesforce, Google Sheets, and PostgreSQL connection credentials/URLs, and the MCP server port.
3. Click the **Flogo 3** icon in the VS Code activity bar → in **RUNTIME EXPLORER**, add a Local Runtime with the **+** button, set any required environment variables, and **Save**.
4. In **FLOGO3: WORKSPACE APPS EXPLORER**, select the app module → right-click → **Run As Executable**. The native binary is produced in the app's `bin/` folder and logs stream to the integrated terminal. This will start the MCP Server on port `8080`.

    *Note: In this example, the application is running as a VS Code app executable. You can alternatively generate a `build.zip` from the **TIBCO Flogo® - App Build Command Line Interface** to deploy in a Data Plane on TIBCO Platform. For more information on how to generate a local build, please refer to [TIBCO Flogo® - App Build Command Line Interface](https://docs.tibco.com/pub/flogo/3.0.0/doc/html/Default.htm#flogo-all/flogo-base-commands.htm?Highlight=build%20cli).*

![MCP local binary start ](https://raw.githubusercontent.com/tp-devhub-hackathon-2025/user-assets-hackathon/main/screenshots/customer-health-monitor/03-chm-startbinary.png)

5. Configure the MCP Server URL (`http://localhost:8080/mcp`) in Claude Desktop or GitHub Copilot in VS Code (see the `claude_desktop_config.json` snippet below). You can then send queries in natural language and receive responses that pull unified insights across Salesforce, Google Sheets, and PostgreSQL, as shown below.

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
</content>
</invoke>
