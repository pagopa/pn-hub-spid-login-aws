#!/usr/bin/env bash

set -ex

if ( [ $# -ne 4 ] ) then
  echo "This script create a test spidhub instance"
  echo "Usage: $0 <profile> <region> <environment> <user-registry-api-key>"
  echo "<profile> the profile to access AWS account"
  echo "<region>: where to deploy the spidhub instance"
  echo "<environment>: redirection url after successful login"
  echo "<user-registry-api-key>: user registry for this environment"
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
UserRegistryApiKey=$4

BucketName=$(cat "./environments/$ENVIRONMENT/params.json" \
    | jq -r ".Parameters.Storage")
    
echo "Bucket Name:" ${BucketName}

PROJECT=spidhub
STACK_NAME=spidhub
PACKAGE_BUCKET=$BucketName
PACKAGE_PREFIX=package

secretPresent=$( aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  secretsmanager list-secrets \
  --no-paginate \
  | jq -r ".SecretList | .[] | select(.Name==\"$PROJECT-$ENVIRONMENT-hub-login\")" | wc -l )

logSecretPresent=$( aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  secretsmanager list-secrets \
  --no-paginate \
  | jq -r ".SecretList | .[] | select(.Name==\"$PROJECT-$ENVIRONMENT-hub-login-logs\")" | wc -l )


hubLoginEnvFile="./environments/$ENVIRONMENT/storage/config/hub-login/v1/.env"
if ( [ $secretPresent -eq 0 ] ) then
  mkdir -p "./environments/$ENVIRONMENT/certs"

  openssl req -nodes -new -x509 -sha256 -days 365 -newkey rsa:2048 \
    -subj "/C=IT/ST=State/L=City/O=Acme Inc. /OU=IT Department/CN=hub-spid-login-ms" \
    -keyout "./environments/$ENVIRONMENT/certs/key.pem" \
    -out "./environments/$ENVIRONMENT/certs/cert.pem"

  mkdir -p "./environments/$ENVIRONMENT/jwt"
  mkdir -p "./environments/$ENVIRONMENT/logs"

  openssl genrsa -out "./environments/$ENVIRONMENT/jwt/jwt_rsa_key.pem" 2048
  openssl rsa -in "./environments/$ENVIRONMENT/jwt/jwt_rsa_key.pem" \
    -outform PEM -pubout -out "./environments/$ENVIRONMENT/jwt/jwt_rsa_public.pem"

  openssl genrsa -out "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" 2048
  openssl rsa -in "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" \
    -outform PEM -pubout -out "./environments/$ENVIRONMENT/logs/logs_rsa_public.pem"

#  UserRegistryApiKey=$(tr -d '\n' < "./environments/$ENVIRONMENT/UserRegistryApiKey.tmp")
  MakecertPrivate=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/certs/key.pem" | tr -d '\n' | sed -e 's/\\n$//')
  MakecertPublic=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/certs/cert.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  JwtTokenPrivateKey=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/jwt/jwt_rsa_key.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  Jwks=$(docker run -i --rm danedmunds/pem-to-jwk:latest --jwks-out < "./environments/$ENVIRONMENT/jwt/jwt_rsa_public.pem")
  Kid=$(echo "$Jwks" | jq -r '.keys[0].kid')
  LogsPublicKey=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/logs/logs_rsa_public.pem" | tr -d '\n' | sed -e 's/\\n$//' )

  sed -i'.tmp' -e "/^JWT_TOKEN_KID=/s/=.*/=$Kid/" $hubLoginEnvFile 

  SecretString=$(echo "{\"MakecertPrivate\":\"$MakecertPrivate\",\"MakecertPublic\":\"$MakecertPublic\",\"JwtTokenPrivateKey\":\"$JwtTokenPrivateKey\",\"UserRegistryApiKey\":\"$UserRegistryApiKey\",\"LogsPublicKey\":\"$LogsPublicKey\"}" | jq --arg v "$Jwks" '. + {"Jwks":$v}')

  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    secretsmanager create-secret \
    --name $PROJECT-$ENVIRONMENT-hub-login \
    --secret-string "$SecretString"

  # set private key to decrypt logs in a specific secret
  LogsPrivateKey=$( sed -e 's/$/\\n/' "./environments/$ENVIRONMENT/logs/logs_rsa_key.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  LogsSecretString=$(echo "{\"LogsPrivateKey\":\"$LogsPrivateKey\"}")

  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    secretsmanager create-secret \
    --name $PROJECT-$ENVIRONMENT-hub-login-logs \
    --secret-string "$SecretString"

else
  if ( [ $logSecretPresent -eq 0 ] ) then
    echo "Warning: the secret $PROJECT-$ENVIRONMENT-hub-login-logs doesn't exist, please create it using generate-logs-keys.sh script"
    exit 1
  fi

  Kid=$(aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    secretsmanager get-secret-value \
    --no-paginate \
    --secret-id $PROJECT-$ENVIRONMENT-hub-login \
    --query SecretString --output text |  jq -r .Jwks | jq -r '.keys[0].kid')
  sed -i'.tmp' -e "/^JWT_TOKEN_KID=/s/=.*/=$Kid/" $hubLoginEnvFile
fi

aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  cloudformation deploy \
  --template-file "./stacks/storage.yaml" \
  --stack-name "$PROJECT-$ENVIRONMENT-storage" \
  --parameter-overrides Project=$PROJECT Environment=$ENVIRONMENT BucketName=$BucketName \
  --tags Project=$PROJECT Environment=$ENVIRONMENT \
  --no-fail-on-empty-changeset


aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  s3 sync \
  ./environments/$ENVIRONMENT/storage/ \
  s3://$PACKAGE_BUCKET/ \
  --delete

alarmName=""

SkipAlarmTopic=$(cat "./environments/$ENVIRONMENT/params.json" | jq -r '.Parameters.SkipAlarmTopic' )

if ( [ $SkipAlarmTopic="true" ] ) then

  alarmName=$( aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    cloudformation describe-stacks \
    --stack-name "once-$ENVIRONMENT" \
    | jq -r '.Stacks[0].Outputs | .[] | select ( .OutputKey=="AlarmSNSTopicName") | .OutputValue' \
  )

else

  aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    cloudformation deploy \
    --stack-name "$PROJECT-$ENVIRONMENT-alarm" \
    --tags Project=$PROJECT Environment=$ENVIRONMENT \
    --template-file "./stacks/alarm-topic/$ENVIRONMENT.yaml" \

  alarmName=$( aws \
    --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" \
    cloudformation describe-stacks \
    --stack-name "$PROJECT-$ENVIRONMENT-alarm" \
    | jq -r '.Stacks[0].Outputs | .[] | select ( .OutputKey=="AlarmSNSTopicName") | .OutputValue' \
  )

fi

echo ""
echo ""
echo "=== Alarm Name: ${alarmName}"
cat "./environments/$ENVIRONMENT/params.json" \
    | jq ".Parameters.AlarmSNSTopicName = \"${alarmName}\"" \
    | tee "./environments/$ENVIRONMENT/params-enanched.json.tmp"

aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  cloudformation package \
  --template-file "./$STACK_NAME.yaml" \
  --output-template-file "./$STACK_NAME.tmp" \
  --s3-bucket "$PACKAGE_BUCKET" \
  --s3-prefix "$PACKAGE_PREFIX"

aws \
  --profile "$AWS_PROFILE" \
  --region "$AWS_REGION" \
  cloudformation deploy \
  --stack-name "$PROJECT-$ENVIRONMENT" \
  --parameter-overrides "file://environments/$ENVIRONMENT/params-enanched.json.tmp" \
  --tags Project=$PROJECT Environment=$ENVIRONMENT \
  --template-file "./$STACK_NAME.tmp" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --no-fail-on-empty-changeset

rm "./$STACK_NAME.tmp"
