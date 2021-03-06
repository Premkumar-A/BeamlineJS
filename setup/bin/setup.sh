# Build pipeline-manager lambda function
cd ../../notification-line
npm run all

cd ../pipeline-manager
npm run all

cd ../beamline
npm run all

cd ../
source ./setup/config/setup.properties
source ./setup/config/lambda.properties

slack_notify_fn_name=${INFRASTRUCTURE_PREFIX}'-slack-notify'
pipeline_manager_fn_name=${INFRASTRUCTURE_PREFIX}'-pipeline-manager'
beamline_fn_name=${INFRASTRUCTURE_PREFIX}'-beamlineJS'
sns_topic_name=${INFRASTRUCTURE_PREFIX}'-beamlineJS'
iam_role_name=${INFRASTRUCTURE_PREFIX}'-beamlineJS'

function error_exit
{
  if [[ $1 == 255 || $1 == 2 ]];
  then
    echo "$2" 1>&2
    exit 1
  fi;
}

## Setup Beamline infrastructure in all AWS regions
IFS=',' read -a region_array <<< "${AWS_REGIONS}"
for region in ${region_array[@]}
do

node -p 'var fileName="./setup/config/pipeline-manager-env-variables.json"; var file = require(fileName); file.Variables.FUNCTION_PREFIX="'${INFRASTRUCTURE_PREFIX}'"; file.Variables.GIT_TOKEN="'${GITHUB_PERSONAL_TOKEN}'"; file.Variables.BUCKET_NAME="'${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}'";console.log(JSON.stringify(file,null,2)); require("fs").writeFile(fileName, JSON.stringify(file,null,2), (err) => {});'
node -p 'var fileName="./setup/config/beamline-env-variables.json"; var file = require(fileName); file.Variables.FUNCTION_PREFIX="'${INFRASTRUCTURE_PREFIX}'"; file.Variables.GIT_TOKEN="'${GITHUB_PERSONAL_TOKEN}'"; file.Variables.BUCKET_NAME="'${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}'";console.log(JSON.stringify(file,null,2)); require("fs").writeFile(fileName, JSON.stringify(file,null,2), (err) => {});'
	
  ## Create S3 bucket if not exists
  result=`aws --profile ${AWS_PROFILE_NAME} --region ${region} s3 ls s3://${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}`
  statusCode=$?
  if [[ ${statusCode} != 0 ]];
  then
    aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation create-stack \
        --stack-name "beamline-s3-stack-${region}" \
    	--template-body file://./setup/config/create_s3_bucket.json \
        --parameters \
        ParameterKey=BucketNameParam,ParameterValue=${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}

    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error creating S3 stack..."

    echo "Creating S3 bucket with bucket name:"${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}
    sleep 30
    set -e
    stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-s3-stack-${region} --max-items 1 --output text | cut -f 7`
    if [[ -z ${stack_status} ]];
    then
       stack_status=CHECK_AGAIN
    fi;
    while [ ${stack_status} != CREATE_COMPLETE ]
    do
        echo ${stack_status}
        sleep 10
        stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-s3-stack-${region} --max-items 1 --output text | cut -f 7`
        if [[ -z ${stack_status} ]];
        then
           stack_status=CHECK_AGAIN
        fi;
        if [ ${stack_status} == ROLLBACK_COMPLETE ]
        then
           exit 1
        fi;
    done;
    set +e
  else
    echo "S3 bucket already exists..."
  fi;

  ## Upload Beamline lambda functions code to S3 buckets
  aws --profile ${AWS_PROFILE_NAME} --region ${region} s3 cp ./pipeline-manager/pipeline-manager-1.0.0.zip s3://${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}/INFRA/pipeline-manager.zip --sse
  aws --profile ${AWS_PROFILE_NAME} --region ${region} s3 cp ./notification-line/notification-line-1.0.0.zip s3://${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}/INFRA/notification-line.zip --sse
  aws --profile ${AWS_PROFILE_NAME} --region ${region} s3 cp ./beamline/beamline-1.0.0.zip s3://${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region}/INFRA/beamline.zip --sse

  ## Create IAM role if not exists
  result=`aws --profile ${AWS_PROFILE_NAME} iam get-role --role-name ${iam_role_name}`
  statusCode=$?
  if [[ ${statusCode} != 0 ]];
  then
    echo "Creating new IAM role..."
    aws --profile ${AWS_PROFILE_NAME} --region ${region}  cloudformation create-stack \
        --capabilities CAPABILITY_NAMED_IAM \
        --stack-name "beamline-iam-role-stack" \
        --template-body file://./setup/config/create_iam_role.json \
        --parameters \
        ParameterKey=BucketName,ParameterValue=${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX} \
        ParameterKey=RoleName,ParameterValue=${iam_role_name}

    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error creating IAM role stack..."
    echo "Creating IAM role with name:"${iam_role_name}'-'${region}
    sleep 30
    set -e
    stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-iam-role-stack --max-items 1 --output text | cut -f 7`
    if [[ -z ${stack_status} ]];
    then
       stack_status=CHECK_AGAIN
    fi;
    while [ ${stack_status} != CREATE_COMPLETE ]
    do
        echo ${stack_status}
        sleep 10
        stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-iam-role-stack --max-items 1 --output text | cut -f 7`
        if [[ -z ${stack_status} ]];
        then
           stack_status=CHECK_AGAIN
        fi;
        if [ ${stack_status} == ROLLBACK_COMPLETE ]
        then
           exit 1
        fi;
    done;
    set +e
  else
    echo "IAM role already exists..."
  fi;
  role_arn='arn:aws:iam::'${AWS_ACCOUNT_ID}':role/'${iam_role_name}

  ## Create or update Beamline lambda functions & configurations
  ### Slack notification function ###
  set +e
  rm -rf ./outputs/slack_fn_${region}.json
  aws --profile ${AWS_PROFILE_NAME} --region ${region} lambda get-function --function-name ${slack_notify_fn_name} >> ./outputs/slack_fn_${region}.json
  file_size=`du -k ./outputs/slack_fn_${region}.json | cut -f1`
  echo "file_size...${file_size}"
  set -e
  if [[ ${file_size} == 0 ]];
  then
    echo "Creating slack notification function..."
    aws --profile ${AWS_PROFILE_NAME} lambda create-function \
         --region ${region} \
         --function-name ${slack_notify_fn_name} \
         --role ${role_arn} \
    	 --runtime ${NOTIFY_FN_RUNTIME} \
         --handler ${NOTIFY_FN_HANDLER} \
         --description "${NOTIFY_FN_DESC}" \
         --timeout ${NOTIFY_FN_TIMEOUT} \
         --memory-size ${NOTIFY_FN_MEMORY_SIZE} \
         --code S3Bucket=${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region},S3Key=INFRA/notification-line.zip 1>&2
     return_code=$?
     echo "Return code:"${return_code}
     error_exit ${return_code} "Error creating Slack notification lambda function..."
  else
    echo "Updating slack notification function..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-code \
        --function-name ${slack_notify_fn_name} \
        --region ${region} \
        --s3-bucket ${S3_BUCKET_NAME}"-"${INFRASTRUCTURE_PREFIX}"-"${region} \
        --s3-key INFRA/notification-line.zip 1>&2
    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification lambda function..."

    echo "Updating slack notification function configurations..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-configuration \
        --function-name ${slack_notify_fn_name} \
        --role ${role_arn} \
        --handler ${NOTIFY_FN_HANDLER} \
        --description "${NOTIFY_FN_DESC}" \
        --timeout ${NOTIFY_FN_TIMEOUT} \
        --memory-size ${NOTIFY_FN_MEMORY_SIZE} 1>&2

    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification function configurations..."
  fi

  ### Pipeline manager function ###
  set +e
  rm -rf ./outputs/pipeline-manager_fn_${region}.json
  aws --profile ${AWS_PROFILE_NAME} --region ${region} lambda get-function --function-name ${pipeline_manager_fn_name} >> ./outputs/pipeline-manager_fn_${region}.json
  file_size=`du -k ./outputs/pipeline-manager_fn_${region}.json | cut -f1`
  echo "file_size...${file_size}"
  set -e
  if [[ ${file_size} == 0 ]];
  then
    echo "Creating pipeline manager function..."
    aws --profile ${AWS_PROFILE_NAME} lambda create-function \
         --region ${region} \
         --function-name ${pipeline_manager_fn_name} \
         --role ${role_arn} \
    	 --runtime ${PIPELINE_MGR_FN_RUNTIME} \
         --handler ${PIPELINE_MGR_FN_HANDLER} \
         --description "${PIPELINE_MGR_FN_DESC}" \
         --timeout ${PIPELINE_MGR_FN_TIMEOUT} \
         --environment file://./setup/config/pipeline-manager-env-variables.json \
         --memory-size ${PIPELINE_MGR_FN_MEMORY_SIZE} \
         --code S3Bucket=${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region},S3Key=INFRA/pipeline-manager.zip 1>&2
     return_code=$?
     echo "Return code:"${return_code}
     error_exit ${return_code} "Error creating Slack notification lambda function..."
  else
    echo "Updating pipeline manager function..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-code \
        --function-name ${pipeline_manager_fn_name} \
        --region ${region} \
        --s3-bucket ${S3_BUCKET_NAME}"-"${INFRASTRUCTURE_PREFIX}"-"${region} \
        --s3-key INFRA/pipeline-manager.zip 1>&2
    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification lambda function..."

    echo "Updating pipeline manager function configurations..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-configuration \
        --function-name ${pipeline_manager_fn_name} \
        --role ${role_arn} \
        --handler ${PIPELINE_MGR_FN_HANDLER} \
        --description "${PIPELINE_MGR_FN_DESC}" \
        --timeout ${PIPELINE_MGR_FN_TIMEOUT} \
        --environment file://./setup/config/pipeline-manager-env-variables.json \
        --memory-size ${PIPELINE_MGR_FN_MEMORY_SIZE} 1>&2
    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification function configurations..."
  fi

  ### BeamlineJS function ###
  set +e
  rm -rf ./outputs/beamlineJS_fn_${region}.json
  aws --profile ${AWS_PROFILE_NAME} --region ${region} lambda get-function --function-name ${beamline_fn_name} >> ./outputs/beamlineJS_fn_${region}.json
  file_size=`du -k ./outputs/beamlineJS_fn_${region}.json | cut -f1`
  echo "file_size...${file_size}"
  set -e
  if [[ ${file_size} == 0 ]];
  then
    echo "Creating beamlineJS function..."
    aws --profile ${AWS_PROFILE_NAME} lambda create-function \
         --region ${region} \
         --function-name ${beamline_fn_name} \
         --role ${role_arn} \
    	 --runtime ${BEAMLINE_FN_RUNTIME} \
         --handler ${BEAMLINE_FN_HANDLER} \
         --description "${BEAMLINE_FN_DESC}" \
         --timeout ${BEAMLINE_FN_TIMEOUT} \
         --environment file://./setup/config/beamline-env-variables.json \
         --memory-size ${BEAMLINE_FN_MEMORY_SIZE} \
         --code S3Bucket=${S3_BUCKET_NAME}'-'${INFRASTRUCTURE_PREFIX}'-'${region},S3Key=INFRA/beamline.zip 1>&2
     return_code=$?
     echo "Return code:"${return_code}
     error_exit ${return_code} "Error creating Slack notification lambda function..."
  else
    echo "Updating beamlineJS function..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-code \
        --function-name ${beamline_fn_name} \
        --region ${region} \
        --s3-bucket ${S3_BUCKET_NAME}"-"${INFRASTRUCTURE_PREFIX}"-"${region} \
        --s3-key INFRA/beamline.zip 1>&2
    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification lambda function..."

    echo "Updating beamlineJS function configurations..."
    aws --profile ${AWS_PROFILE_NAME} lambda update-function-configuration \
        --function-name ${beamline_fn_name} \
        --role ${role_arn} \
        --handler ${BEAMLINE_FN_HANDLER} \
        --description "${BEAMLINE_FN_DESC}" \
        --timeout ${BEAMLINE_FN_TIMEOUT} \
        --environment file://./setup/config/beamline-env-variables.json \
        --memory-size ${BEAMLINE_FN_MEMORY_SIZE} 1>&2
    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error updating slack notification function configurations..."
  fi

  ## Create or Update SNS Topic & subscription
  set +e
  snsTopicARN=`aws --profile ${AWS_PROFILE_NAME} --region ${region} sns list-topics --output text | cut -f2 | grep ${sns_topic_name}`
  set -e
  echo ${snsTopicARN}
  if [[ -z ${snsTopicARN} ]]
  then
    echo "Creating SNS Topic..."
    aws --profile ${AWS_PROFILE_NAME} --region ${region}  cloudformation create-stack \
        --stack-name "beamline-sns-topic-stack-${region}" \
        --template-body file://./setup/config/create_sns_topic.json \
        --parameters \
        ParameterKey=lambdaFunctionARN,ParameterValue='arn:aws:lambda:'${region}':'${AWS_ACCOUNT_ID}':function:'${pipeline_manager_fn_name} \
        ParameterKey=snsTopicName,ParameterValue=${sns_topic_name}

    return_code=$?
    echo "Return code:"${return_code}
    error_exit ${return_code} "Error creating SNS topic stack..."
    echo "Creating SNS Topic with name:"${sns_topic_name}
    sleep 30
    set -e
    stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-sns-topic-stack-${region} --max-items 1 --output text | cut -f 7`
    if [[ -z ${stack_status} ]];
    then
       stack_status=CHECK_AGAIN
    fi;
    while [ ${stack_status} != CREATE_COMPLETE ]
    do
        echo ${stack_status}
        sleep 10
        stack_status=`aws --profile ${AWS_PROFILE_NAME} --region ${region} cloudformation describe-stacks --stack-name beamline-sns-topic-stack-${region} --max-items 1 --output text | cut -f 7`
        if [[ -z ${stack_status} ]];
        then
           stack_status=CHECK_AGAIN
        fi;
        if [ ${stack_status} == ROLLBACK_COMPLETE ]
        then
           exit 1
        fi;
    done;
    snsTopicARN=`aws --profile ${AWS_PROFILE_NAME} --region ${region} sns list-topics --output text | cut -f2 | grep ${sns_topic_name}`
    set +e
  else
    echo "Updating SNS Topic..."
    set -e
    rm -rf ./outputs/subscription.json
    aws --profile ${AWS_PROFILE_NAME} --region ${region} sns list-subscriptions-by-topic --topic-arn ${snsTopicARN} >> ./outputs/subscription.json
    subARN=`node -p 'require("./outputs/subscription.json").Subscriptions[0].SubscriptionArn'`
    endpointARN=`node -p 'require("./outputs/subscription.json").Subscriptions[0].Endpoint'`
    aws --profile ${AWS_PROFILE_NAME} --region ${region} sns unsubscribe --subscription-arn ${subARN}
    aws --profile ${AWS_PROFILE_NAME} --region ${region} sns subscribe --topic-arn ${snsTopicARN} --protocol lambda --notification-endpoint ${endpointARN}
    set +e
  fi;

  ## setup SNS integration only if region is primary region
  if [[ ${region} == ${PRIMARY_AWS_REGION} ]];
  then
    ## Create Amazon SNS integration on the repositories
    IFS=',' read -a url_array <<< "${REPOSITORY_HOOKS_URLS}"
    for url in ${url_array[@]};
    do
      curl -v -b -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: token ${GITHUB_PERSONAL_TOKEN}" \
      -d '{
      	"name": "amazonsns",
      	"active": true,
      	"events": ["push", "pull_request"],
        "config": {
          "aws_key": "'"${AWS_ACCESS_KEY}"'",
          "aws_secret": "'"${AWS_SECRET_KEY}"'",
          "sns_topic": "'"${snsTopicARN}"'",
          "sns_region": "'"${PRIMARY_AWS_REGION}"'"
        }
      }' \
      "${url}"
    done
  fi;
done

git checkout HEAD ./setup/config/pipeline-manager-env-variables.json
git checkout HEAD ./setup/config/beamline-env-variables.json

