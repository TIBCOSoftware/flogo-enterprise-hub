#!/bin/bash

CONTAINER_REGISTRY_IMAGE=localhost:30100/pythonmlif:latest

cat <<PACKAGE > ./Dockerfile
FROM python:3.13.7-slim-bookworm
#FROM python:3.9-slim-buster
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
#CMD ["python", "main.py"]
#CMD ["fastapi", "dev", "main.py"]
CMD ["fastapi", "run", "main.py"]
PACKAGE

cat <<PACKAGE > ./pythonmlif.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pythonmlif
  labels:
    app: pythonmlif
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pythonmlif
  template:
    metadata:
      labels:
        app: pythonmlif
    spec:
      containers:
      - name: pythonmlif
        image: ${CONTAINER_REGISTRY_IMAGE}
        ports:
        - containerPort: 5000 # Or your application's port
---
apiVersion: v1
kind: Service
metadata:
    name: pythonmlif
spec:
  selector:
    app: pythonmlif
  ports:
    - name: http
      protocol: TCP
      port: 80 # Or desired external port
      targetPort: 8000 # Or your application's port
  type: ClusterIP # Or ClusterIP, NodePort, LoadBalancer depending on exposure needs
PACKAGE

# Endpoint:  pythonmlif.python.svc.cluster.local

docker build -t pythonmlif .
docker tag pythonmlif:latest ${CONTAINER_REGISTRY_IMAGE}
docker push ${CONTAINER_REGISTRY_IMAGE}

kubectl create namespace python --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f pythonmlif.yaml -n python

# kubectl get all -n python

# Teardown
# kubectl delete -f pythonmlif.yaml -n python
# docker rmi ${CONTAINER_REGISTRY_IMAGE}
# docker rmi pythonmlif

# Test Python App
# kubectl run -it --rm --image=alpine/curl test-shell --namespace=python -- sh
# curl http://10.98.1.220/isabnormal/70
# exit

# kubectl exec -it pod/pythonmlif-6f9495b5d-v5rdl -n python -- /bin/bash
# kubectl logs pod/pythonmlif-6f9495b5d-v5rdl -n python