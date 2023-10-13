#!/usr/bin/env bash

set -ex

if ( [ $# -ne 3 ] ) then
  echo "This script create a test spidhub instance"
  echo "Usage: $0 <profile> <region> <environment>"
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


PROJECT=spidhub
STACK_NAME=spidhub

secretPresent=$( aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  secretsmanager list-secrets \
  --max-items 100 \
  | jq -r ".SecretList | .[] | select(.Name==\"$PROJECT-$ENVIRONMENT-hub-login-logs\")" | wc -l )


if ( [ $secretPresent -eq 0 ] ) then

  openssl genrsa -out "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" 2048
  openssl rsa -in "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" \
    -outform PEM -pubout -out "./environments/$ENVIRONMENT/logs/logs_rsa_public.pem"

  LogsPublicKey=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/logs/logs_rsa_public.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  LogsPrivateKey=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" | tr -d '\n' | sed -e 's/\\n$//' )

  SecretString=$(echo "{\"LogsPrivateKey\":\"$LogsPrivateKey\"}")

  echo ""
  echo ""
  echo ""
  echo " ==== Start LogsPublicKey to Update in Secret $PROJECT-$ENVIRONMENT-hub-login ==== "
  echo $LogsPublicKey
  echo " ==== End LogsPublicKey to Update in Secret $PROJECT-$ENVIRONMENT-hub-login ==== "
  echo ""
  echo ""
  echo ""
  
  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    secretsmanager create-secret \
    --name $PROJECT-$ENVIRONMENT-hub-login-logs \
    --secret-string "$SecretString"
else
  echo "Secret $PROJECT-$ENVIRONMENT-hub-login-logs already present"
fi

