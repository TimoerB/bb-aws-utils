install_awscli() {
  apt-get update
  apt-get install -y python-dev
  curl -O https://bootstrap.pypa.io/get-pip.py
  python get-pip.py
  pip install awscli
}

set_source_ecr_credentials() {
  AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_ECR_SOURCE}"
  AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_ECR_SOURCE}"
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  eval $(aws ecr get-login --no-include-email --region ${AWS_REGION_SOURCE:-eu-central-1})
}

docker_build_deploy_image() {
  echo "FROM ${AWS_ACCOUNTID_SRC}.dkr.ecr.${AWS_REGION_SOURCE:-eu-central-1}.amazonaws.com/${REPONAME}:latest" > Dockerfile
  docker build -t ${REPONAME}-${ENVIRONMENT:-dev} .
}

set_dest_ecr_credentials() {
  AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID_ECR_TARGET}"
  AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY_ECR_TARGET}"
  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  eval $(aws ecr get-login --no-include-email --region ${AWS_REGION_TARGET:-eu-central-1})
}

docker_tag_and_push_deploy_image() {
  docker tag ${REPONAME}-${ENVIRONMENT:-dev} ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${REPONAME}-${ENVIRONMENT:-dev}
  docker push ${AWS_ACCOUNTID_TARGET}.dkr.ecr.${AWS_REGION_TARGET:-eu-central-1}.amazonaws.com/${REPONAME}-${ENVIRONMENT:-dev}
}
