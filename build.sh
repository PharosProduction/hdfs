#!/usr/bin/env bash

ORGANIZATION="dmytronasyrov"
DOCKER_REPO="hdfs"
DATE="13-05-25"
VERSION="1"

VCS_URL="https://github.com/PharosProduction/hdfs"
VCS_BRANCH="hdfs/master"
VCS_REF="40charsSHA-1hashOfCommit"

docker buildx stop
docker buildx create --use --name serverbuilder --node serverbuilder0 --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=1073741824

################################################################################

docker buildx build \
  --build-arg build_date=$DATE \
  --build-arg vcs_url=$VCS_URL \
  --build-arg vcs_branch=$VCS_BRANCH \
  --build-arg vcs_ref=$VCS_REF \
  --platform linux/arm64,linux/amd64 \
  -f Dockerfile \
  --progress plain \
  --push \
  -t $ORGANIZATION/$DOCKER_REPO:$DATE-$VERSION \
  .

################################################################################

docker buildx stop