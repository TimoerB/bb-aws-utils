#!/usr/bin/env bash

AWSCLI_INSTALLED=0
JQ_INSTALLED=0
CW_ALARMS_DISABLED=0
CW_ALARMS=NA

run_log_and_exit_on_failure() {
  echo "### Starting ${1}"
  if eval "${1}"
  then
    echo "### ${1} successfully executed"
  else
    _enable_cw_alarms
    echo "### ERROR: ${1} failed, exiting ..."
    exit 1
  fi
}

install_awscli() {
  if [[ ${AWSCLI_INSTALLED} -eq 0 ]]
  then
    run_log_and_exit_on_failure "apt-get update"
    run_log_and_exit_on_failure "apt-get install -y python-dev"
    run_log_and_exit_on_failure "curl -O https://bootstrap.pypa.io/get-pip.py"
    run_log_and_exit_on_failure "python get-pip.py"
    run_log_and_exit_on_failure "pip install awscli"
    AWSCLI_INSTALLED=1
  else
    echo "### awscli already installed ###"
  fi
}

install_maven2() {
  echo "### Start maven2 installation ###"
  run_log_and_exit_on_failure "apt-get update"
  run_log_and_exit_on_failure "apt-get install -y maven2"
}

install_jq() {
  if [[ ${AWSCLI_INSTALLED} -eq 0 ]]
  then
    echo "### Start jq installation ###"
    run_log_and_exit_on_failure "apt-get update"
    run_log_and_exit_on_failure "apt-get install -y jq"

    ### jq is required
    if ! which jq >/dev/null 2>&1
    then
    echo "### jq is required ###"
    exit 1
    else
    echo "### jq is installed ###"
    fi
  else
    echo "### jq already installed ###"
  fi
}

repo_git_url() {
  echo "git@bitbucket.org:${REMOTE_REPO_OWNER}/${REMOTE_REPO_SLUG}.git"
}

create_TAG_file_in_remote_url() {
  # To make sure the deploy pipeline uses the correct docker image tag,
  # this functions:
  #   - clones the remote repo
  #   - creates or updates a file named TAG in the root of the repo
  #   - the TAG file contains the commit hash of the SW git repo commit
  #   - adds, commits ans pushes the changes
  # The pipeline of the config repo will then use the content of the file
  # to determine the tag of the docker image to pull and use to create
  # the deploy image.
  #
  # This requires that pipeline to have a SSH key:
  #   bb -> repo -> settings -> pipelines -> SSH keys
  #
  # That ssh key should be granted read/write permissions to the repo
  # to be cloned, changed, committed and pushed, and will be available
  # as ~/.ssh/id_rsa

  ### It's useless to do this if no SSHKEY is configured in the pipeline.
  if [[ ! -e /opt/atlassian/pipelines/agent/data/id_rsa ]]
  then
    echo "### ERROR: No SSH Key is configured in the pipeline, and this is required ###"
    echo "###        to be able to add/update the TAG file in the remote (config)   ###"
    echo "###        repository.                                                    ###"
    echo "###        Add a key to the repository and try again.                     ###"
    echo "###            bb -> repo -> settings -> pipelines -> SSH keys            ###"
    exit 1
  fi

  ### Construct remote repo HTTPS URL
  REMOTE_REPO_URL=$(repo_git_url)
  echo "### Remote repo URL is ${REMOTE_REPO_URL} ###"

  ### git config
  git config --global user.email "bitbucketpipeline@wherever.com"
  git config --global user.name "Bitbucket Pipeline"

  echo "### Trying to clone ${REMOTE_REPO_URL} into remote_repo ###"
  rm -rf remote_repo
  git clone ${REMOTE_REPO_URL} remote_repo || { echo "### Error cloning ${REMOTE_REPO_URL} ###"; exit 1; }
  echo "### Update the TAG file in the repo ###"
  echo "${BITBUCKET_COMMIT}" > remote_repo/TAG
  cd remote_repo
  git add TAG
  ### If 2 pipelines run on same commit, the TAG file will not change
  if ! git diff-index --quiet HEAD --
  then
    echo "### TAG file was updated, committing and pushing the change ###"
    git commit -m 'Update TAG with source repo commit hash' || { echo "### Error committing TAG ###"; exit 1; }
    git push || { echo "### Error pushing to ${REMOTE_REPO_URL} ###"; exit 1; }
  else
    echo "### TAG file was unchanged, because the pipeline for this commit has been run before. ###"
    echo "### No further (git) actions required.                                                ###"
  fi

  ### If this build is triggered by a git tag, also put the tag on the config repo
  if [[ -n ${BITBUCKET_TAG} ]]
  then
    echo "### This build is triggered by a tag, also put the tag ${BITBUCKET_TAG} on the config repo ###"
    echo "### ${REMOTE_REPO_URL} ###"
    git tag ${BITBUCKET_TAG}
    git push --tags
  fi

  REMOTE_REPO_COMMIT_HASH=$(git rev-parse HEAD)
  echo "### Full commit hash of remote repo is ${REMOTE_REPO_COMMIT_HASH} ###"
  cd -
}

monitor_automatic_remote_pipeline_start() {
  ### This function is used to monitor the pipeline build that was automatically triggered
  ### by a commit or by adding a tag in create_TAG_file_in_remote_url. This is a requirement
  ### to make release candidate/release process work.
  ### The choice between starting the remote pipeline build or monitoring the remote
  ### pipeline build is made by setting the environment variable MONITOR_REMOTE_PIPELINE:
  ###    - envvar ONLY_MONITOR_REMOTE_PIPELINE is set and has value 1: use this function
  ###    - envvar ONLY_MONITOR_REMOTE_PIPELINE is not set or has value 0: trigger the remote
  ###      pipelind
  ### That envvar is evaluated in the script sync_trigger_bb_build.bash script

  export URL="https://api.bitbucket.org/2.0/repositories/${REMOTE_REPO_OWNER}/${REMOTE_REPO_SLUG}/pipelines/?pagelen=1&sort=-created_on"


  echo "### Waiting 30 seconds to allow the branch or tag triggered build to start ###"
  sleep 30

  echo "### Retrieve information about the most recent remote pipeline ###"
  CURLRESULT=$(curl -X GET -s -u "${BB_USER}:${BB_APP_PASSWORD}" -H 'Content-Type: application/json' ${URL})

  UUID=$(echo ${CURLRESULT} | jq --raw-output '.values[0].uuid' | tr -d '\{\}')
  BUILDNUMBER=$(echo ${CURLRESULT} | jq --raw-output '.values[0].build_number' | tr -d '\{\}')

  monitor_running_pipeline '.values[0].state.name'
}

start_pipeline_for_remote_repo() {
  ### See comments in monitor_automatic_remote_pipeline_start

  REMOTE_REPO_COMMIT_HASH=${1}
  PATTERN=${2:-build_and_deploy}

  URL="https://api.bitbucket.org/2.0/repositories/${REMOTE_REPO_OWNER}/${REMOTE_REPO_SLUG}/pipelines/"

  echo ""
  echo "### REMOTE_REPO_OWNER:       ${REMOTE_REPO_OWNER} ###"
  echo "### REMOTE_REPO_SLUG:        ${REMOTE_REPO_SLUG} ###"
  echo "### URL:                     ${URL} ###"
  echo "### REMOTE_REPO_COMMIT_HASH: ${REMOTE_REPO_COMMIT_HASH} ###"

  cat > /curldata << EOF
{
  "target": {
    "commit": {
      "hash":"${REMOTE_REPO_COMMIT_HASH}",
      "type":"commit"
    },
    "selector": {
      "type":"custom",
      "pattern":"${PATTERN}"
    },
    "type":"pipeline_commit_target"
  }
}
EOF
  CURLRESULT=$(curl -X POST -s -u "${BB_USER}:${BB_APP_PASSWORD}" -H 'Content-Type: application/json' \
                    ${URL} -d '@/curldata')


  UUID=$(echo "${CURLRESULT}" | jq --raw-output '.uuid' | tr -d '\{\}')
  BUILDNUMBER=$(echo "${CURLRESULT}" | jq --raw-output '.build_number')

  if [[ ${UUID} = "null" ]]
  then
    echo "### ERROR: An error occured when triggering the pipeline ###"
    echo "###        for ${REMOTE_REPO_SLUG} ###"
    echo "### Curl data and return object follow ###"
    cat /curldata
    echo "###"
    echo "${CURLRESULT}" | jq .
    exit 1
  fi

  monitor_running_pipeline '.state.name'
}

monitor_running_pipeline() {

  JQ_EXPRESSION=${1:-.state.name}
  JQ_EXPRESSION=".state.name"

  URL="https://api.bitbucket.org/2.0/repositories/${REMOTE_REPO_OWNER}/${REMOTE_REPO_SLUG}/pipelines/"

  echo "### Remote pipeline is started and has UUID is ${UUID} ###"
  echo "### Build UUID: ${UUID} ###"
  echo "### Build Number: ${BUILDNUMBER} ###"
  echo ""
  echo "### Link to the remote pipeline result is: ###"
  echo "###   https://bitbucket.org/${REMOTE_REPO_OWNER}/${REMOTE_REPO_SLUG}/addon/pipelines/home#!/results/${BUILDNUMBER} ###"

  CONTINUE=1
  SLEEP=10
  STATE="NA"
  RESULT="na"
  CURLRESULT="NA"

  echo "### Monitoring remote pipeline with UUID ${UUID} with interval ${SLEEP} ###"
  echo "### JQ_EXPRESSION: ${JQ_EXPRESSION} ###"

  while [[ ${CONTINUE} = 1 ]]
  do
    sleep ${SLEEP}
    CURLRESULT=$(curl -X GET -s -u "${BB_USER}:${BB_APP_PASSWORD}" -H 'Content-Type: application/json' ${URL}\\{${UUID}\\})
    STATE=$(echo ${CURLRESULT} | jq --raw-output "${JQ_EXPRESSION}")

    echo ${CURLRESULT} | jq .

    echo "  ### Pipeline is in state ${STATE} ###"

    if [[ ${STATE} == "COMPLETED" ]]
    then
      CONTINUE=0
    fi
  done

  RESULT=$(echo ${CURLRESULT} | jq --raw-output '.state.result.name')
  echo "### Pipeline result is ${RESULT} ###"

  RETURNVALUE="${RESULT}"
}

set_credentials() {
  access_key=${1}
  secret_key=${2}
  echo "### Setting environment for AWS authentication ###"
  AWS_ACCESS_KEY_ID="${access_key}"
  AWS_SECRET_ACCESS_KEY="${secret_key}"
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
}

set_source_ecr_credentials() {
  set_credentials "${AWS_ACCESS_KEY_ID_ECR_SOURCE}" "${AWS_SECRET_ACCESS_KEY_ECR_SOURCE}"
  echo "### Logging in to AWS ECR source ###"
  eval $(aws ecr get-login --no-include-email --region ${AWS_REGION_SOURCE:-eu-central-1})
}

docker_build() {
  install_awscli
  eval $(aws ecr get-login --no-include-email --region ${AWS_REGION_SOURCE:-eu-central-1})
  ### The Dockerfile is supposed to be in a subdir docker of the repo
  MYDIR=$(pwd)
  if [[ -e /${BITBUCKET_CLONE_DIR}/docker/Dockerfile ]]
  then
    cd /${BITBUCKET_CLONE_DIR}/docker
  elif [[ -e /${BITBUCKET_CLONE_DIR}/Dockerfile ]]
  then
    cd /${BITBUCKET_CLONE_DIR}
  else
    echo "### ERROR - No dockerfile found where expected (/${BITBUCKET_CLONE_DIR}/docker/Dockerfile or ###"
    echo "### /${BITBUCKET_CLONE_DIR}/Dockerfile. Exiting ..."
    exit 1
   fi

  echo "### Start build of docker image ${DOCKER_IMAGE} ###"
  _docker_build ${DOCKER_IMAGE}
  echo "### Tagging docker image ${DOCKER_IMAGE}:${BITBUCKET_COMMIT} ###"
  docker tag ${DOCKER_IMAGE} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}
  docker tag ${DOCKER_IMAGE} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_COMMIT}

  echo "### Pushing docker image ${DOCKER_IMAGE}:${BITBUCKET_COMMIT} to ECR ###"
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_COMMIT}

  if [[ -n ${BITBUCKET_TAG} ]] && [[ -n ${RC_PREFIX} ]] && [[ ${BITBUCKET_TAG} = ${RC_PREFIX}* ]]
  then
    echo "### Building a release candidate, also add the ${BITBUCKET_TAG} tag on the docker image ###"
    docker tag ${DOCKER_IMAGE} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_TAG}
    docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_TAG}
  fi

  cd ${MYDIR}
}

docker_build_application_image() {
  echo "### Docker info ###"
  docker info
  echo "### Start build of docker image ${DOCKER_IMAGE} ###"
  _docker_build ${DOCKER_IMAGE}
}

set_dest_ecr_credentials() {
  echo "### Fallback to AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY if AWS_ACCESS_KEY_ID_ECR_TARGET or AWS_SECRET_ACCESS_KEY_ECR_TARGET are not defined"
  [[ -z ${AWS_ACCESS_KEY_ID_ECR_TARGET} ]] && [[ -n ${AWS_ACCESS_KEY_ID} ]] && AWS_ACCESS_KEY_ID_ECR_TARGET=${AWS_ACCESS_KEY_ID}
  [[ -z ${AWS_SECRET_ACCESS_KEY_ECR_TARGET} ]] && [[ -n ${AWS_SECRET_ACCESS_KEY} ]] && AWS_SECRET_ACCESS_KEY_ECR_TARGET=${AWS_SECRET_ACCESS_KEY}
  set_credentials "${AWS_ACCESS_KEY_ID_ECR_TARGET}" "${AWS_SECRET_ACCESS_KEY_ECR_TARGET}"
  echo "### Logging in to AWS ECR target ###"
  eval $(aws ecr get-login --no-include-email --region ${AWS_REGION_TARGET:-eu-central-1})
}

docker_build_deploy_image() {
  echo "### Determine the TAG to use for the docker pull from the file named TAG ###"
  export TAG="latest"

  echo "### Create deploy Dockerfile ###"
  echo "###    - use the content of the TAG file as the label for the docker image"
  echo "###      to build FROM, unless ...."
  echo "###    - REL_PREFIX is defined and RC_PREFIX is defined and the BITBUCKET_TAG"
  echo "###      being built starts with REL_REFIX. This indicates a production"
  echo "###      build that should use the corresponding ACC build (with a RC tag)"
  echo ""
  echo "### REL_PREFIX:       ${REL_PREFIX:-NA} ###"
  echo "### RC_PREFIX:        ${RC_PREFIX:-NA} ###"
  echo "### BITBUCKET_TAG:    ${BITBUCKET_TAG:-NA} ###"
  echo "### BITBUCKET_COMMIT: ${BITBUCKET_COMMIT:-NA} ###"

  if [[ -n ${BITBUCKET_TAG} ]] && [[ -n ${RC_PREFIX} ]] && [[ -n ${REL_PREFIX} ]] && [[ ${BITBUCKET_TAG} = ${REL_PREFIX}* ]]
  then
    TAG=${RC_PREFIX}${BITBUCKET_TAG##${REL_PREFIX}}
    echo "### Building a release, use the release candidate artefact image with tag ${TAG} ###"
  else
    [[ -e TAG ]] && TAG=$(cat TAG)
    echo "### Not a release build, use artefact image with tag ${TAG} ###"
  fi

  echo "FROM ${AWS_ACCOUNTID_SRC}.dkr.ecr.${AWS_REGION_SOURCE:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${TAG:-latest}" > Dockerfile

  IMAGE=${DOCKER_IMAGE}

  if [[ -n ${DOCKER_IMAGE_TARGET} ]]
  then
    ### Possibility to override target image
    IMAGE=${DOCKER_IMAGE_TARGET}
  fi

  echo "### Start build of docker image ${IMAGE}-${ENVIRONMENT:-dev} based on the artefact image with tag ${TAG:-latest} ###"
  _docker_build ${IMAGE}-${ENVIRONMENT:-dev}
}

docker_tag_and_push_deploy_image() {
  IMAGE=${DOCKER_IMAGE}

  if [[ -n ${DOCKER_IMAGE_TARGET} ]]
  then
    ### Possibility to override target image
    IMAGE=${DOCKER_IMAGE_TARGET}
  fi

  echo "### Tagging docker image ${IMAGE}-${ENVIRONMENT:-dev} ###"
  docker tag ${IMAGE}-${ENVIRONMENT:-dev} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${IMAGE}-${ENVIRONMENT:-dev}
  echo "### Pushing docker image ${IMAGE}-${ENVIRONMENT:-dev} to ECR ###"
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${IMAGE}-${ENVIRONMENT:-dev}
}

docker_tag_and_push_application_image() {
  echo "### Tagging docker image ${DOCKER_IMAGE} ###"
  docker tag ${DOCKER_IMAGE} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}
  docker tag ${DOCKER_IMAGE} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_COMMIT}
  echo "### Pushing docker image ${DOCKER_IMAGE} to ECR ###"
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${DOCKER_IMAGE}:${BITBUCKET_COMMIT}
}

docker_deploy_image() {
  if [[ -n ${CW_ALARM_SUBSTR} ]]
  then
    echo "### Disable all CloudWatch alarm actions to avoid panic reactions ###"
    _disable_cw_alarms
  fi

  echo "### Force update service ${ECS_SERVICE} on ECS cluster ${ECS_CLUSTER} in region ${AWS_REGION} ###"
  run_log_and_exit_on_failure "aws ecs update-service --cluster ${ECS_CLUSTER} --force-new-deployment --service ${ECS_SERVICE} --region ${AWS_REGION:-eu-central-1}"

  if [[ -n ${CW_ALARM_SUBSTR} ]]
  then
    echo "### Allow the service to stabilize before re-enabling alarms (120 seconds)  ###"
    sleep 30
    echo "###    90 seconds remaining  ###"
    sleep 30
    echo "###    60 seconds remaining  ###"
    sleep 30
    echo "###    30 seconds remaining  ###"
    sleep 30
    echo "### Enable all CloudWatch alarm actions to guarantee the services being monitored ###"
    _enable_cw_alarms
  fi
}

s3_deploy_apply_config_to_tree() {
  # In all files under ${basedir}, replace all occurences of __VARNAME__ to the value of
  # the environment variable CFG_VARNAME, for all envvars starting with CFG_
  basedir=${1}

  for VARNAME in ${!CFG_*}
  do
    SUBST_SRC="__${VARNAME##CFG_}__"
    SUBST_VAL=$(eval echo \$${VARNAME})
    echo "### Replacing all occurences of ${SUBST_SRC} to ${SUBST_VAL} in all files under ${basedir} ###"
    find ${basedir} -type f | xargs sed -i "" "s|${SUBST_SRC}|${SUBST_VAL}|g"
  done
}

s3_deploy_create_tar_and_upload_to_s3() {
  echo "### Create tarfile ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz from all files in ${PAYLOAD_LOCATION:-dist} ###"
  tar -C ${PAYLOAD_LOCATION:-dist} -czvf ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz .
  echo "### Copy ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz to S3 bucket ${S3_ARTIFACT_BUCKET}/${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz ###"
  aws s3 cp ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz s3://${S3_ARTIFACT_BUCKET}/${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz
  echo "### Copy ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz to S3 bucket ${S3_ARTIFACT_BUCKET}/${ARTIFACT_NAME}-last.tgz ###"
  aws s3 cp ${ARTIFACT_NAME}-${BITBUCKET_COMMIT}.tgz s3://${S3_ARTIFACT_BUCKET}/${ARTIFACT_NAME}-last.tgz
}

s3_deploy_download_tar_and_prepare_for_deploy() {
  echo "### Download artifact ${ARTIFACT_NAME}-last.tgz from s3://${S3_ARTIFACT_BUCKET} ###"
  aws s3 cp s3://${S3_ARTIFACT_BUCKET}/${ARTIFACT_NAME}-last.tgz .
  ###   *
  echo "### Create workdir ###"
  mkdir -p workdir
  echo "### Untar the artifact file into the workdir ###"
  tar -C workdir -xzvf ${ARTIFACT_NAME}-last.tgz
  echo "### Start applying the config to the untarred files ###"
  s3_deploy_apply_config_to_tree workdir
}

s3_deploy_deploy() {
  install_awscli
  cd ${1:-workdir}
  echo "### Set AWS credentials for deploy (AWS_ACCESS_KEY_ID_S3_TARGET and AWS_SECRET_ACCESS_KEY_S3_TARGET) ###"
  set_credentials "${AWS_ACCESS_KEY_ID_S3_TARGET}" "${AWS_SECRET_ACCESS_KEY_S3_TARGET}"
  echo "### Deploy the payload to s3://${S3_DEST_BUCKET}/${S3_PREFIX:-} with ACL ${AWS_ACCESS_CONTROL:-private} ###"
  aws s3 cp --acl ${AWS_ACCESS_CONTROL:-private} --recursive . s3://${S3_DEST_BUCKET}/${S3_PREFIX:-}
  cd -
}

s3_deploy() {
  install_awscli
  echo "### Set AWS credentials for artifact download (AWS_ACCESS_KEY_ID_S3_SOURCE and AWS_SECRET_ACCESS_KEY_S3_SOURCE) ###"
  set_credentials "${AWS_ACCESS_KEY_ID_S3_SOURCE}" "${AWS_SECRET_ACCESS_KEY_S3_SOURCE}"
  s3_deploy_download_tar_and_prepare_for_deploy
  echo "### Start the deploy ###"
  s3_deploy_deploy
}

s3_lambda_build_and_push() {
  export CI=false
  install_awscli
  run_log_and_exit_on_failure "apt-get install -y zip"
  run_log_and_exit_on_failure "mkdir -p /builddir"

  ### Node
  if [[ ${LAMBDA_RUNTIME} = nodejs* ]]
  then
    [[ -e ${LAMBDA_FUNCTION_FILE:-index.js} ]] && run_log_and_exit_on_failure "mv -f ${LAMBDA_FUNCTION_FILE:-index.js} /builddir"
    if [[ -f package.json ]]
    then
      run_log_and_exit_on_failure "npm install"
      [[ -e node_modules ]] && run_log_and_exit_on_failure "mv -f node_modules /builddir"
    fi
  fi

  ### Python
  if [[ ${LAMBDA_RUNTIME} = python* ]]
  then
    [[ -e ${LAMBDA_FUNCTION_FILE:-lambda.py} ]] && run_log_and_exit_on_failure "mv -f ${LAMBDA_FUNCTION_FILE:-lambda.py} /builddir"
    if [[ -f requirements.txt ]]
    then
      run_log_and_exit_on_failure "pip install -r requirements.txt --target /builddir"
    fi
  fi

  echo "### Zip the Lambda code and dependencies"
  run_log_and_exit_on_failure "cd /builddir"
  run_log_and_exit_on_failure "zip -r /${LAMBDA_FUNCTION_NAME}.zip *"
  run_log_and_exit_on_failure "cd -"

  echo "### Push the zipped file to S3 bucket ${S3_DEST_BUCKET}"
  set_credentials "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}"
  run_log_and_exit_on_failure "aws s3 cp --acl private /${LAMBDA_FUNCTION_NAME}.zip s3://${S3_DEST_BUCKET}/${LAMBDA_FUNCTION_NAME}.zip"
  run_log_and_exit_on_failure "aws s3 cp --acl private /${LAMBDA_FUNCTION_NAME}.zip s3://${S3_DEST_BUCKET}/${LAMBDA_FUNCTION_NAME}-${BITBUCKET_COMMIT}.zip"
}

s3_artifact() {
  install_awscli
  echo "### Run the build command (${BUILD_COMMAND:-No build command}) ###"
  create_npmrc
  [[ -n ${BUILD_COMMAND} ]] && eval ${BUILD_COMMAND}
  echo "### Set AWS credentials for artifact upload (AWS_ACCESS_KEY_ID_S3_TARGET and AWS_SECRET_ACCESS_KEY_S3_TARGET) ###"
  set_credentials "${AWS_ACCESS_KEY_ID_S3_TARGET}" "${AWS_SECRET_ACCESS_KEY_S3_TARGET}"
  s3_deploy_create_tar_and_upload_to_s3
}

create_npmrc() {
  echo "### Create ~/.npmrc file for NPMJS authentication ###"
  echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN:-NA}" > ~/.npmrc
}

clone_repo() {
  ### Construct remote repo HTTPS URL
  REMOTE_REPO_URL=$(repo_git_url)

  echo "### Remote repo URL is ${REMOTE_REPO_URL} ###"

  ### git config
  git config --global user.email "bitbucketpipeline@wherever.com"
  git config --global user.name "Bitbucket Pipeline"

  echo "### Trying to clone ${REMOTE_REPO_URL} into remote_repo ###"
  run_log_and_exit_on_failure "rm -rf remote_repo"
  run_log_and_exit_on_failure "git clone --single-branch -b ${REMOTE_REPO_BRANCH:-master} ${REMOTE_REPO_URL} remote_repo"
  
  run_log_and_exit_on_failure "cd remote_repo"
  run_log_and_exit_on_failure "git checkout $(cat ../TAG)"
  run_log_and_exit_on_failure "cd -" 
}

s3_cloudfront_invalidate() {
  if [[ -n ${CLOUDFRONT_DISTRIBUTION_ID} ]]
  then
    run_log_and_exit_on_failure "aws cloudfront create-invalidation --distribution-id ${CLOUDFRONT_DISTRIBUTION_ID} --paths '/*'"
  else
    echo "### WARNING: Skipping cloudfront invalidation because CLOUDFRONT_DISTRIBUTION_ID is not set ###"
  fi
}

s3_build_once_deploy_once() {
  ### This is for legacy stuff and Q&D pipeline migrations
  ###   * clone a repository REMOTE_REPO_SLUG for REMOTE_REPO_OWNER and branch REMOTE_REPO_BRANCH )default is master)
  ###   * run the BUILD_COMMAND
  ###   * copy all files in PAYLOAD_LOCATION (default is dist) to s3://${S3_DEST_BUCKET}/${S3_PREFIX:-} with ACL ${AWS_ACCESS_CONTROL:-private}
  ###   * invalidate the CloudFront Distribution CLOUDFRONT_DISTRIBUTION_ID
  ### For S3 authentication: AWS_ACCESS_KEY_ID_S3_TARGET and AWS_SECRET_ACCESS_KEY_S3_TARGET
  ### Use SSH private key to be able to clone the repository

  clone_repo
  ### clone_repo clones in the remote_repo directory
  run_log_and_exit_on_failure "cd remote_repo"
  run_log_and_exit_on_failure "${BUILD_COMMAND}"

  echo "### Set AWS credentials for deploy (AWS_ACCESS_KEY_ID_S3_TARGET and AWS_SECRET_ACCESS_KEY_S3_TARGET) ###"
  set_credentials "${AWS_ACCESS_KEY_ID_S3_TARGET}" "${AWS_SECRET_ACCESS_KEY_S3_TARGET}"
  echo "### Start the deploy ###"
  install_awscli
  s3_deploy_deploy ${PAYLOAD_LOCATION}
  s3_cloudfront_invalidate

  run_log_and_exit_on_failure "cd -"
}

#####################
### Private functions

_disable_cw_alarms() {
  CW_ALARMS=$(aws cloudwatch describe-alarms --region ${AWS_REGION:-eu-central-1} --query "MetricAlarms[*]|[?contains(AlarmName, '${CW_ALARM_SUBSTR}')].AlarmName" --output text)
  if aws cloudwatch disable-alarm-actions --region ${AWS_REGION:-eu-central-1} --alarm-names ${CW_ALARMS:-NoneFound}
  then
    CW_ALARMS_DISABLED=1
  fi
}

_enable_cw_alarms() {
  if [[ ${CW_ALARMS_DISABLED} -eq 1 ]]
  then
    if aws cloudwatch enable-alarm-actions --region ${AWS_REGION:-eu-central-1} --alarm-names ${CW_ALARMS:-NoneFound}
    then
      CW_ALARMS_DISABLED=0
    fi
  fi
}

_docker_build() {
  image_name=${1:-${DOCKER_IMAGE}}

  echo "### Start build of docker image ${DOCKER_IMAGE} ###"
  docker build --build-arg="BITBUCKET_COMMIT=${BITBUCKET_COMMIT:-NA}" \
               --build-arg="BITBUCKET_REPO_SLUG=${BITBUCKET_REPO_SLUG:-NA}" \
               --build-arg="BITBUCKET_REPO_OWNER=${BITBUCKET_REPO_OWNER:-NA}" \
               -t ${image_name} .
}
