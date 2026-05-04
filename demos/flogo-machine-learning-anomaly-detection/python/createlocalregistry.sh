#!/bin/bash

# Ref: https://medium.com/@lumontec/running-container-registries-inside-k8s-6564aed42b3a

cat <<PACKAGE > ${HOME}/kube-registry.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: kube-registry
---
apiVersion: v1
kind: Service
metadata:
  labels:
    app: registry
  name: registry
  namespace: kube-registry
spec:
  ports:
  - nodePort: 30100
    port: 5000
    protocol: TCP
    targetPort: 5000
  selector:
    app: registry
  type: NodePort
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: kube-registry
spec:
  storageClassName: "standard"
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: registry
  name: registry
  namespace: kube-registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - image: registry:2
        imagePullPolicy: IfNotPresent
        name: registry
        volumeMounts:
        - mountPath: /var/lib/registry
          name: registry-vol
      volumes:
      - name: registry-vol
        persistentVolumeClaim:
          claimName: registry-pvc
PACKAGE

kubectl apply -f ${HOME}/kube-registry.yaml
# Teardown: kubectl delete -f ${HOME}/kube-registry.yaml

kubectl get all -n kube-registry
kubectl port-forward service/registry 30100:5000 -n kube-registry

# Below applicable to ATS Demo Image only
SLEEP_BETWEEN_TASK_SEC=5
ASSET_FOLDER=/home/$USER/asset
CONTAINER_NAMESPACE="kube-registry"
CONTAINER_TARGET="service/registry"
HOST_MACHINE_PORT="30100"
CONTAINER_PORT="5000"

if [ ! -f /etc/systemd/system/kubectlportforward_${HOST_MACHINE_PORT}.service ] ; then
    
    cat <<EOT > ~/kubectlportforward_${HOST_MACHINE_PORT}.service
    [Unit]
    Description=kubectl port forward
    After=minikube.service

    [Service]
    Type=simple
    ExecStart=${ASSET_FOLDER}/startkubectlportforward.sh ${CONTAINER_NAMESPACE} ${CONTAINER_TARGET} ${HOST_MACHINE_PORT} ${CONTAINER_PORT}
    RemainAfterExit=true
    ExecStop=${ASSET_FOLDER}/stopkubectlportforward.sh ${HOST_MACHINE_PORT}
    StandardOutput=journal
    User=$USER
    Group=$USER

    [Install]
    WantedBy=multi-user.target
EOT

    sudo mv ~/kubectlportforward_${HOST_MACHINE_PORT}.service /etc/systemd/system/kubectlportforward_${HOST_MACHINE_PORT}.service
    sudo systemctl daemon-reload
    sudo systemctl start kubectlportforward_${HOST_MACHINE_PORT}
    sleep ${SLEEP_BETWEEN_TASK_SEC}

    sudo systemctl enable kubectlportforward_${HOST_MACHINE_PORT}
    sleep ${SLEEP_BETWEEN_TASK_SEC}
fi
