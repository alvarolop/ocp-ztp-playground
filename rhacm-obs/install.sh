#!/bin/bash

source ./aws-env-vars

# User defined variables
ACM_NAMESPACE=open-cluster-management
ACMO_NAMESPACE=open-cluster-management-observability
AWS_S3_BUCKET_ACMO=acm-observability-bucket

# Print environment variables
echo -e "\n=============="
echo -e "ENVIRONMENT VARIABLES:"
echo -e " * AWS_ACCESS_KEY_ID: $AWS_ACCESS_KEY_ID"
echo -e " * AWS_SECRET_ACCESS_KEY: $AWS_SECRET_ACCESS_KEY"
echo -e " * AWS_DEFAULT_REGION: $AWS_DEFAULT_REGION"
echo -e " * AWS_S3_BUCKET: $AWS_S3_BUCKET"
echo -e " * ACM_NAMESPACE: $ACM_NAMESPACE"
echo -e " * ACMO_NAMESPACE: $ACMO_NAMESPACE"
echo -e " * AWS_S3_BUCKET_ACMO: $AWS_S3_BUCKET_ACMO"
echo -e "==============\n"

if ! which aws &> /dev/null; then 
    echo "You need the AWS CLI to run this Quickstart, please, refer to the official documentation:"
    echo -e "\thttps://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    exit 1
fi

echo -n "Waiting for ACM cluster to be running (Currently: $(oc get multiclusterhub -n $ACM_NAMESPACE -o=jsonpath='{.items[0].status.phase}'))..."
# oc wait --for=condition=running multiclusterhub multiclusterhub -n $ACM_NAMESPACE
while [[ $(oc get multiclusterhub -n $ACM_NAMESPACE -o=jsonpath='{.items[0].status.phase}') != "Running" ]]; do echo -n "." && sleep 1; done; echo -n -e "  [OK]\n"


echo -e "\n========================"
echo -e "= Create the S3 Bucket ="
echo -e "========================\n"

if aws s3api head-bucket --bucket $AWS_S3_BUCKET_ACMO &> /dev/null; then
    echo -e "Check. S3 bucket already exists, do nothing."
else
    echo -e "Check. Creating S3 bucket..."
    aws s3api create-bucket \
    --bucket $AWS_S3_BUCKET_ACMO \
    --region $AWS_DEFAULT_REGION \
    --create-bucket-configuration LocationConstraint=$AWS_DEFAULT_REGION
fi


echo -e "\n======================="
echo -e "= Create req. secrets ="
echo -e "=======================\n"

oc apply -f rhacm-obs/ns-open-cluster-management-observability.yaml

DOCKER_CONFIG_JSON=`oc extract secret/pull-secret -n openshift-config --to=-`

oc create secret generic multiclusterhub-operator-pull-secret \
    -n $ACMO_NAMESPACE \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson \
    --dry-run=client -o yaml | oc apply -f -


cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: thanos-object-storage
  namespace: $ACMO_NAMESPACE
type: Opaque
stringData:
  thanos.yaml: |
    type: s3
    config:
      bucket: $AWS_S3_BUCKET_ACMO
      endpoint: s3.$AWS_DEFAULT_REGION.amazonaws.com
      access_key: $AWS_ACCESS_KEY_ID
      secret_key: $AWS_SECRET_ACCESS_KEY
EOF

echo -e "\n======================="
echo -e "=    INSTALL ACMO     ="
echo -e "=======================\n"

oc apply -f rhacm-obs/mco-observability.yaml
oc apply -f rhacm-obs/cm-observability-metrics-custom-allowlist.yaml

echo -n "Waiting for Grafana route creation..." 
until oc get route grafana -n $ACMO_NAMESPACE >/dev/null 2>&1; do echo -n "." && sleep 1; done; echo -n -e "  [OK]\n"

GRAFANA_ROUTE=$(oc get routes grafana -n $ACMO_NAMESPACE --template="https://{{.spec.host}}") \
envsubst < rhacm-obs/consolelink-open-cluster-management-observability-grafana.yaml | oc apply -f -
