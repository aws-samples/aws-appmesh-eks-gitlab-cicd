#!/bin/bash

function check_versioning(){
    version_result=`aws dynamodb get-item --consistent-read --table-name versioning --key '{ "app_name": {"S": "'$APP_NAME'"}}'`
    current_ver=`echo $version_result | jq -r '.Item.current_ver.S'`
    init_ver=`echo $version_result | jq -r '.Item.init_ver.S'`
    if [ -z $current_ver ];then
        export CURRENT_VERSION=${CI_PIPELINE_ID} 
        export INIT_VERSION=${CI_PIPELINE_ID} 
    else
        if [ "$current_ver" != "${CI_PIPELINE_ID}" ];then
            export CURRENT_VERSION=${CI_PIPELINE_ID}
        else
            export CURRENT_VERSION=$current_ver
        fi
        export INIT_VERSION=$init_ver
    fi
}

check_versioning

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export NAMESPACE=appmesh-ns 

echo "AWS_DEFAULT_REGION: "$AWS_DEFAULT_REGION
echo "ACCOUNT_ID: "$ACCOUNT_ID
echo "APP_NAME: "$APP_NAME
echo "INIT VERSION: "$INIT_VERSION
echo "CURRENT VERSION: "$CURRENT_VERSION
echo "INIT WEIGHT: "$INIT_WEIGHT
echo "NEW WEIGHT: "$NEW_WEIGHT

cd manifests/

if [ $1 == "deploy" ];then
    export APP_VERSION=$CURRENT_VERSION && echo "APP VERSION: "$APP_VERSION

    # --- Mesh ---#
    kubectl apply -f mesh.yml

    # --- Virtualnode ---#
    eval "cat <<EOF
$(<templates/virtualnode.yml.template)
EOF
    " >virtualnode.yml
    kubectl apply -f virtualnode.yml -n $NAMESPACE

    # # --- Deployment ---#
    eval "cat <<EOF
$(<templates/deployment.yml.template)
EOF
    " >deployment.yml
    kubectl apply -f deployment.yml --record -n $NAMESPACE

    SERVICE_RESP="$(kubectl get virtualservice flask -n $NAMESPACE 2>&1)"     

    # # --- Virtualservice ---#
    kubectl apply -f virtualservice.yml -n $NAMESPACE

    if [[ $SERVICE_RESP =~ "NotFound" ]]
    then
        echo "Service does not exists"
        # # --- Virtualrouter ---#
        eval "cat <<EOF
$(<templates/virtualrouter.yml.template)
EOF
        " >virtualrouter.yml
        kubectl apply -f virtualrouter.yml -n $NAMESPACE
    else
        # # --- Virtualrouter Canary ---#
        eval "cat <<EOF
$(<templates/virtualrouter-canary.yml.template)
EOF
        " >virtualrouter.yml
        kubectl apply -f virtualrouter.yml -n $NAMESPACE
    fi

    # --- Virtual Ingress gw ---#
    kubectl apply -f virtualgateway.yml -n $NAMESPACE

    aws dynamodb put-item --table-name versioning \
        --item '{"app_name": {"S": "'$APP_NAME'"}, "current_ver": {"S": "'$CURRENT_VERSION'"}, "init_ver": {"S": "'$INIT_VERSION'"}}'

elif [ $1 == "destroy" ];then
    export APP_VERSION=$INIT_VERSION && echo "APP VERSION: "$APP_VERSION

    export INIT_VERSION=$CURRENT_VERSION
    export INIT_WEIGHT=100
    eval "cat <<EOF
$(<templates/virtualrouter.yml.template)
EOF
    " >virtualrouter.yml
    kubectl apply -f virtualrouter.yml -n $NAMESPACE

    # --- Deployment ---#
    eval "cat <<EOF
$(<templates/deployment.yml.template)
EOF
    " >deployment.yml
    kubectl delete -f deployment.yml -n $NAMESPACE

    eval "cat <<EOF
$(<templates/virtualnode.yml.template)
EOF
    " >virtualnode.yml
    kubectl delete -f virtualnode.yml -n $NAMESPACE

    aws dynamodb put-item --table-name versioning \
        --item '{"app_name": {"S": "'$APP_NAME'"}, "current_ver": {"S": "'$CURRENT_VERSION'"}, "init_ver": {"S": "'$CURRENT_VERSION'"}}'
fi

