#!/usr/bin/env bash

set -ex

if ( [ $# -ne 3 ] ) then
  echo "This script create a test spidhub instance"
  echo "Usage: $0 <profile> <region> <environment> <user-registry-api-key>"
  echo "<profile> the profile to access AWS account"
  echo "<region>: where to deploy the spidhub instance"
  echo "<environment>: redirection url after successful login"
  echo " other parameters are retrieved from the specific environments directory"
  echo "This script require following executable configured in the PATH variable:"
  echo " - aws cli 2.0 "
  echo " - jq"

  if ( [ "$BASH_SOURCE" = "" ] ) then
    return 1
  else
    exit 1
  fi
fi

AWS_PROFILE=$1
AWS_REGION=$2
ENVIRONMENT=$3

CLUTERS_JSON=$(aws ecs --profile $AWS_PROFILE --region $AWS_REGION list-clusters --no-cli-pager --query "clusterArns" --output json)
CLUTERS=$( jq -nrc "$CLUTERS_JSON | .[]")
for CLUSTER in $CLUSTERS; do
  echo "cluster $CLUSTER"
  $CLUSTER_REGEX= _REGEX="^arn:aws:ecs:.*:cluster/spidhub-.*$"
  if [[ $CLUSTER =~ $CLUSTER_REGEX ]]; then
    echo "CLUSTER found"
    aws ecs --profile dev-spidhub --region eu-south-1 list-services --cluster $CLUSTER --service spidhub-dev-spid-saml-check --force-new-deployment
  fi
done

exit
# aws ecs --profile dev-spidhub --region eu-south-1 list-clusters --no-cli-pager
# aws ecs --profile dev-spidhub --region eu-south-1 list-services --cluster  "arn:aws:ecs:eu-south-1:954693996334:cluster/spidhub-dev-Orchestrator-CJ8AH0YC1EZW-Cluster-HzBvnknvw8Bl"
# aws ecs --profile dev-spidhub --region eu-south-1 list-services --cluster  "arn:aws:ecs:eu-south-1:954693996334:cluster/spidhub-dev-Orchestrator-CJ8AH0YC1EZW-Cluster-HzBvnknvw8Bl" --service spidhub-dev-spid-saml-check --force-new-deployment
