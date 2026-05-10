
# MCP Server in FLOGO for TIBCO Managed File Transfer -  How to build

## Introduction

With **TIBCO Flogo®  Model Context Protocol (MCP) Connector**, enterprises can now expose their systems and business logic as **AI-accessible tools**, enabling secure, intelligent automation across CRM, order management, and communication systems — all **without writing code**.  

**TIBCO Managed File Transfer** provides a single point of control to manage all of your enterprise file transfers, both inside and outside the enterprise, with freedom of choice in deployment. MFT runs across all major platforms from Windows to the Mainframe or modern deployment options like **containers either on premise or in the cloud**.

This demo showcases how Flogo MCP Connector can turn a TIBCO Managed File Transfer system into **AI-powered B2B service experiences**.

## Demo Overview

 **In this demonstration, we build a **Managed File Transfer B2B AI agent** using the Flogo MCP Connector. It illustrates how the three MCP primitives — **Resources**, **Tools**, and **Prompts** — work together to connect AI models (like Claude or N8N with OpenAI model) with enterprise data from the Managed File Transfer system in a controlled, compliant, and context-aware way.


![image info](images/FLOGO_MCP_MFT/MCP-Server-for-Flogo-Overview.png)

## Get started

### Prerequisites for building/running this demonstration:
- TIBCO MFT environment 
*I used a TIBCO MFT installation in a docker desktop environment running the [command center](https://docs.tibco.com/products/tibco-managed-file-transfer-command-center-8-6-0) and [internet server](https://docs.tibco.com/products/tibco-managed-file-transfer-internet-server) in a docker container.*

![image info](images/FLOGO_MCP_MFT/DockerDesktop.png)
- Visual Code Studio with the Flogo Plugin
- Claude Desktop can be downloaded from the link below:  
   [https://claude.ai/download](https://claude.ai/download)
- Docker Desktop can be obtained from the link below:  
   [https://www.docker.com/products/docker-desktop/](https://www.docker.com/products/docker-desktop/)

#### Flogo MCP Server

The MCP Server is build in [TIBCO Flogo Enterprise](https://docs.tibco.com/products/tibco-flogo-enterprise).  Download the "TIBCO Flogo Extension for Visual Studio Code Software" from the [eDelivery portal](https://www.tibco.com/downloads/11810/secure/download-11810).

In the Flogo MCP Server multiple flows are defined. For each MCP - Tool definition a separate flow is specified. In this example MCP Server, there are 3 MCP Tool definitions available:
- Transfers Tool
- Users Tool
- Audits Tool

![image info](images/FLOGO_MCP_MFT/FLOGO_MCP1.png)

The MCP-Tool definition is the actual flow definition which is responsible for collecting the requested data to service the LLM models. In the example below an impression is shown of the Audits Tool flow definition. 

![image info](images/FLOGO_MCP_MFT/FLOGO_MCP2.png)


##### Installing the Visual Studio Code plugin

After installing the VSCode Studio, it is needed to install the Flogo-plugin that is available via the e-Delivery portal. The plugin is downloaded in \*.vsix format and can be installed via the plugin perspective in VSCode. By clicking the 3 dots next to the center separator (See image below), you can open the menu, where the "install from vsix" is one of the menu options. Now select the downloaded vsix-file and install the plugin. 

![image info](images/FLOGO_MCP_MFT/VSCode1.png)

After a succesfull installation, the plugin should be visible in the list with installed plugins.

![image info](images/FLOGO_MCP_MFT/VSCode2.png)

##### Setup a runtime environment

Navigate to the Flogo component in the activity bar on the left side.
Move over the RUNTIME EXPLORER bar, which then shows the plus sign to add runtimes to the workspace. 

![image info](images/FLOGO_MCP_MFT/VSCode4.png)

Select the Local Runtime option from the dropdown list 

![image info](images/FLOGO_MCP_MFT/VSCode5.png)

Provide the runtime configuration with a name.

![image info](images/FLOGO_MCP_MFT/VSCode6.png)

#### Import the Flogo application


![image info](images/FLOGO_MCP_MFT/VSCode7.png)

Click on the flogo application in the list, which will open the Flogo Editor.


Now continue with additional configuration steps, needed to match your environment details.

##### Configure the Managed File Transfer credentials and endpoints

![image info](images/FLOGO_MCP_MFT/FLOGO_MCP3.png)


In each flow it is needed to adjust the MFT Rest API endpoints so they will match with your environment. Open the flows and alter the Invoke activity as is shown in the below illustrations.

![image info](images/FLOGO_MCP_MFT/FLOGO_MCP6.png)


![image info](images/FLOGO_MCP_MFT/FLOGO_MCP5.png)


The next step is to start the application in the test environment.
First select the right runtime environment for this Flogo application.
You can select this by clicking on the "Actions" bar in the "Flogo App" section of the Explorer view.

![image info](images/FLOGO_MCP_MFT/VSCode8.png)

After selecting the proper runtime environment. The application can be started via the *Run* command. This will compile and start the application.

![image info](images/FLOGO_MCP_MFT/VSCode3.png)

You now have a running Flogo MCP Server for Managed File Transfer, that can be used from you AI MCP Client tooling. In my description, I have tested with the Claude Desktop environment from Anthropic.

#### Claude Desktop Configuration

In the Claude Desktop configuration the Flogo MCP Server should be registered as a Local MCP Server. You will need to update the *claude_desktop_config.json* file with the following definitions.
Navigate to: >File >Settings >Developer and edit the file accordingly.

```
{
    "mcpServers": {
        "FLOGO:MFTData": {
            "command": "npx",
            "args": [
                "mcp-remote",
                "http://localhost:9098/mcp"
            ]
        }
    }
}

```


Navigate to: >File >Settings >Developer
In the configuration of the MCP Servers, you should be able to see the FLOGO MCP Server in the running status.

![image info](images/FLOGO_MCP_MFT/Claude_CFG3.png)


Navigate back to the Chat screen and click the "Search and Tools" button


![image info](images/FLOGO_MCP_MFT/Claude_CFG1.png)


![image info](images/FLOGO_MCP_MFT/Claude_CFG2.png)

