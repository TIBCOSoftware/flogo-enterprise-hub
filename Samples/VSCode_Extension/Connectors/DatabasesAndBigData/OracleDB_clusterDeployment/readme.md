# Deploy and Run Flogo Oracle DB Application in a Docker Container and Local Kubernetes Cluster.


## Description

This example demonstrates how we can deploy and run Flogo Oracle DB app in Docker container and local kubernetes cluster using minikube.
Flogo Oracle DB app need runtime oracle client libraries to run app. In the attached Docker file, we are installing the runtime dependencies for Flogo oracle DB app. 

The main purpose of this sample is:
* To deploy and run the Flogo oracle DB app in a docker container.
* To run Flogo Oracle DB app in minikube cluster.

## Prerequisites

1. Ensure that docker and Minikube cluster is up and running. Here will be using minikube as the local Kubernetes (K8s) cluster for deploying and managing applications.
3. In order to deploy and run Flogo Oracle DB app make sure Docker file, deployment.yml file and Flogo Oracle DB app binary should be present at same location.

## Deploy and Run Flogo Oracle DB app in a docker container

1. Create a folder and place your Flogo Oracle DB app binary and Docker file in it.

2. Now open terminal from this location.

3. Build Flogo Oracle DB app image using below command:
    
    `docker build -t  oracle-app .`

    Here docker reads the Dockerfile to create an image and tags it with the name oracle-app.
    
    > **Note:** There is a dot (.) at the end of the command that represents the current directory, which contains the Dockerfile and other files used during the build.

    ![Build Flogo Oracle DB app in docker](../../../images/OracleDatabase/33.png)

4. Check for oracle-app image is created or not using below command:
    
    `docker images`

    ![Verify image created](../../../images/OracleDatabase/34.png)

5. Run oracle-app docker image using below command:
    
    `docker run -i -t -p 9999:9999 oracle-app`

    Here above command maps port 9999 on the host machine to port 9999 within the oracle-app container. It is needed because the application endpoint is exposed on port 9999.

    ![Run Flogo Oracle DB app](../../../images/OracleDatabase/35.png)

6. Hit below curl command to get output: 
    
    `curl http://localhost:9999/orcl`

    Here above command sends an HTTP request to your local machine (localhost) on port 9999, requesting the /orcl endpoint.

    ![Curl output](../../../images/OracleDatabase/36.png)

7. Check oracle-app logs using below command:
    
    `docker logs <<CONTAINER_ID>>`

    > **eg:** docker logs 645562ba2fc3

    ![Flogo Oracle DB app logs](../../../images/OracleDatabase/37.png)

8. Check running container using below command:
    
    `docker ps -a`

    ![Verify running conatainer](../../../images/OracleDatabase/38.png)
  

## Deploy and Run Flogo Oracle DB app in Minikube Cluster

1. Use image name and tag which gets created after building above Flogo Oracle DB app eg. oracle-app:latest and Update your deployment.yml file accordingly.

2. Load above created image into minikube using below command:
  
    `minikube image load oracle-app:latest` 

3. Check that above image is load into minikube or not using below command:
    
    `minikube image list`

    ![Image is loaded into minikube and verify into list](../../../images/OracleDatabase/39.png)

4. User need to run below command for docker to point to the minikube:

    `eval $(minikube docker-env)`

5. Apply updated deployment.yml file changes using below command:
  
    `kubectl apply -f deployment.yaml`

    Here above command tells Kubernetes to create or update resources based on the configurations defined in the deployment.yaml file.

    ![Create or update yaml file and verify pod is created](../../../images/OracleDatabase/40.png)

6. Check pods using below command:
    
    `kubectl get pods`

7. Check logs using below command:
    
    `kubectl logs <podname>`
    
      > **eg:** kubectl logs oracleapp-deployment-7889cff7-2fsjh

8. Forward port to access your app locally on the same port using below command:
    
    `kubectl port-forward <podname> 9999:9999`
    
      > **eg:** kubectl port-forward oracleapp-deployment-7889cff7-2fsjh 9999:9999

    ![Port forward to 9999](../../../images/OracleDatabase/41.png)

9. Hit below curl command to get output: 
    
    `curl http://localhost:9999/orcl`

    ![Curl output](../../../images/OracleDatabase/42.png)  

10. Again Check logs using below command:
    
    `kubectl logs <podname>`

    ![Verify app logs](../../../images/OracleDatabase/43.png)

11. You can scale down the app using below command:
    
    `kubectl scale deploy <deployment-metadata-name> --replicas=0`
    
      > **eg:** kubectl scale deploy oracleapp1-deployment --replicas=0

    ![Sacle down app](../../../images/OracleDatabase/44.png)


## Understanding Dockerfile and deployment.yaml file configuration

### Understanding Dokcerfile

In the Dockerfile,
1. Base Image:
    
    ```dockerfile
    FROM alpine:latest
    ```

    This Uses Alpine Linux as the base image.

2. Install Dependencies:
    
    ```dockerfile
    RUN apk add --no-cache ca-certificates libaio bash curl unzip \
      && mkdir -p /opt/oracle \
      && apk add gcompat
    ```

    This Installs necessary tools (SSL certificates, libraries, bash, curl, unzip, gcompat) to support Oracle Instant Client and the Flogo app.
    After installing these dependencies, it creates a directory /opt/oracle for Oracle files using mkdir -p /opt/oracle.

3. Download and Install Oracle Instant Client:  
    
    ```dockerfile
    WORKDIR /opt/oracle
    RUN curl -O https://download.oracle.com/otn_software/linux/instantclient/2113000/instantclient-basic-linux.x64-21.13.0.0.0dbru.zip \
      && unzip instantclient-basic-linux.x64-21.13.0.0.0dbru.zip \
      && rm instantclient-basic-linux.x64-21.13.0.0.0dbru.zip
    ```

    It downloads and installs Oracle Instant Client into /opt/oracle.


4. Set Environment Variables:
  
    ```dockerfile
    ENV LD_LIBRARY_PATH="/opt/oracle/instantclient_21_13"
    ENV PATH="/opt/oracle/instantclient_21_13:$PATH"
    ```

    It Configures LD_LIBRARY_PATH and PATH to point to the Oracle Instant Client.

5. Set Working Directory and Add Flogo App:
    
    ```dockerfile
    WORKDIR /app
    ADD oracleapp /app/flogoapp
    ```

    Copies the application files from the host machine to the container.

6. Set Entrypoint:
    
    ```dockerfile
    CMD ["/app/flogoapp"]
    ```

    Defines the default command to run the Flogo application when the container starts.
 

### Understanding deployment.yaml file

1. apiVersion:
    
    ```yaml
    apiVersion: apps/v1
    ```
  
    This specifies the version of the Kubernetes API you're using to create the deployment. Here it is set to apps/v1, which is standard for deployments.

2. kind:
    
    ```yaml
    kind: Deployment
    ```
    
    This defines the kind of Kubernetes resource being created. In this case, it is a Deployment, which is used to manage stateless applications and ensure a specified number of replicas are running.

3. metadata:
    
    ```yaml
    metadata:
      name: oracleapp1-deployment
      labels:
        app: oracleapp1
    ```

  Metadata provides information about the deployment:
  * name: The name of the deployment is oracleapp1-deployment.  
  * labels: This assigns a label app: oracleapp1 to the deployment, which is useful for selecting resources with the same label.

4. spec:

    ```yaml
    spec:
      replicas: 1  # You can change this if you want to scale
      selector:
        matchLabels:
          app: oracleapp1
    ```

  The spec section defines the specifications for the deployment:
  * replicas: Specifies the number of identical pods to be running. It’s set to 1, meaning only one pod will be running, but you can scale it by changing this number.
  * selector: Defines how the deployment will identify which pods to manage. In this case, it uses the label app: oracleapp1.

5. template:

    ```yaml
    template:
      metadata:
        labels:
          app: oracleapp1
      spec:
        containers:
          - name: oracleapp1-container
            image: oracle-app1:latest  # Replace with your image
            imagePullPolicy: IfNotPresent
            ports:
              - containerPort: 9999  # Replace with your app's exposed port
            env:
              - name: LD_LIBRARY_PATH
                value: "/opt/oracle/instantclient_21_13"
              - name: PATH
                value: "/opt/oracle/instantclient_21_13:$PATH"
    ```

  The template defines the pod template for the deployment:
  * metadata.labels: This ensures that the pods created by the deployment will also have the label 'app: oracleapp1'.
  * spec.containers: Describes the container(s) that will be deployed inside the pod:
    * name: The container's name is oracleapp1-container.
    * image: Specifies the Docker image to use, here it is docker.io/library/oracle-app1:latest. This should be replaced with your actual image if different.
    * imagePullPolicy: Set to IfNotPresent, which means that Kubernetes will only pull the image from the container registry if the image is not already present on the node. If the image is already cached locally on the node (i.e., the same version is already present), Kubernetes will not pull it again and will use the locally cached image instead.
    * ports: The container exposes port 9999, which should match the port your application listens to.
    * env: Defines environment variables for the container:
      * LD_LIBRARY_PATH: Points to the Oracle Instant Client location.
      * PATH: Appends the Oracle Instant Client path to the system’s PATH environment variable.


## Outputs

1. Application run using Docker

![App Response when executed in docker](../../../images/OracleDatabase/37.png)
![App Response when executed in docker](../../../images/OracleDatabase/45.png)

2. Application run using Kubernets

![App Response when executed in kubernetes](../../../images/OracleDatabase/43.png)
![App Response when executed in kubernetes](../../../images/OracleDatabase/46.png)

## Troubleshooting

* If you see error like: `Cannot locate a 64-bit Oracle Client library: "libclntsh.so: cannot open shared object file: No such file or directory"` then make sure that your docker file installed oracle client libraries successfully
* If you see error like: `couldn't get current server API group list: Get "https://172.24.206.179:8443/api?timeout=32s": dial tcp 172.24.206.179:8443: connectex: A connection attempt failed because the connected party did not properly respond after a period of time, or established connection failed because connected host has failed to respond.` then make sure that your minikube cluster is up and running. If you're using a local setup (like Minikube or Docker Desktop), ensure that the Kubernetes service is started and healthy. 


