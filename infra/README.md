**Prerequisites for Linux & MacOsx:**

- You must have `helm 3.3.0+` installed.
- You must have `awscli 2.0.0+` installed.
- You must have `kubectl 1.19.0+` installed.
- You must have `eksctl 0.26.0+` installed.
- You must have `jq 1.6+` installed.

**1. Create Keypair from AWS console**

Go to AWS EC2 console, create EC2 keypair and download private key. This will be used for EKS nodes later on.

**2. Export following variables**

`export CLUSTER_NAME=<YOUR-EKS-CLUSTER-NAME>`

`export REGION=<YOUR-AWS-REGION>(i.e. us-west-2)`

**3. Create config file for EKS cluster**

Replace `<YOUR-EKS-CLUSTER-NAME>` and `<YOUR-EC2-KEYPAIR-NAME>` with yours in below yaml file, then execute it.

```
cat <<"EOF" > ./cluster_config.yml
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: <YOUR-EKS-CLUSTER-NAME>
  region: us-west-2
nodeGroups:
  - name: <YOUR-EKS-CLUSTER-NAME>-workers
    instanceType: t3.medium
    desiredCapacity: 1
    minSize: 1
    maxSize: 2
    ssh:
      publicKeyName: <YOUR-EC2-KEYPAIR-NAME>
      allow: true
    iam:
      withAddonPolicies:
        autoScaler: true
        externalDNS: true
        albIngress: true
        appMesh: true
        appMeshPreview: true
        xRay: true
        cloudWatch: true
EOF
```

**4. Create EKS cluster**

EKS cluster creation will take approximately 15 min.
```
eksctl create cluster --config-file cluster_config.yaml --kubeconfig kubeconfig_$CLUSTER_NAME.yaml
eksctl utils associate-iam-oidc-provider --cluster=$CLUSTER_NAME  --region=$REGION --approve
```

**5. Export Kubeconfig**

`export KUBECONFIG=kubeconfig_$CLUSTER_NAME.yaml`

**6. Add repos for EKS, and other stable and incubator charts**

```
helm repo add stable https://kubernetes-charts.storage.googleapis.com/
helm repo add incubator http://storage.googleapis.com/kubernetes-charts-incubator
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

**7. Install ALB Ingress controller**

Create IAM Policy for ALB Ingress Controller:
```
wget -O alb-ingress-iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-alb-ingress-controller/master/docs/examples/iam-policy.json
POLICY_ARN=`aws iam create-policy --policy-name ALBIngressControllerIAMPolicy --policy-document file://alb-ingress-iam-policy.json | jq -r ".Policy.Arn"`
```

Create service account for Alb ingress controller with policy created above
```
eksctl create iamserviceaccount \
       --cluster=$CLUSTER_NAME \
       --namespace=kube-system \
       --name=alb-ingress-controller-$CLUSTER_NAME \
       --attach-policy-arn=$POLICY_ARN \
       --override-existing-serviceaccounts \
       --region=$REGION \
       --approve
```
Install ALB ingress controller
```
helm install incubator/aws-alb-ingress-controller --set clusterName=$CLUSTER_NAME --set autoDiscoverAwsRegion=true --set autoDiscoverAwsVpcID=true --generate-name --namespace kube-system
```


**8. Install AppMesh controller**     

Create service account for appmesh-controller
```
kubectl create ns appmesh-system

eksctl create iamserviceaccount --cluster $CLUSTER_NAME \
    --namespace appmesh-system \
    --name appmesh-controller \
    --attach-policy-arn  arn:aws:iam::aws:policy/AWSCloudMapFullAccess,arn:aws:iam::aws:policy/AWSAppMeshFullAccess,arn:aws:iam::aws:policy/AWSAppMeshEnvoyAccess \
    --override-existing-serviceaccounts \
        --region=$REGION \
    --approve
```

Install appmesh-controller
```
helm upgrade -i appmesh-controller eks/appmesh-controller \
    --namespace appmesh-system \
    --set region=$REGION \
    --set serviceAccount.create=false \
    --set serviceAccount.name=appmesh-controller
```

**9. Create Dynamodb table for CI/CD Versioning**

This table will be used by Gitlab CI/CD in canary deployment to track previous and current versions of application
```
export TABLE_NAME=versioning
export REPO_NAME=flask-app

aws dynamodb create-table \
    --table-name $TABLE_NAME \
    --attribute-definitions \
        AttributeName=app_name,AttributeType=S \
    --key-schema \
        AttributeName=app_name,KeyType=HASH \
--provisioned-throughput \
        ReadCapacityUnits=1,WriteCapacityUnits=1

aws ecr create-repository --repository-name $REPO_NAME
        
```