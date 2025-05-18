#!/usr/bin/env bash

ORGANIZATION="dmytronasyrov"
DOCKER_REPO="hdfs"
DATE="18-05-25"
VERSION="2"

HADOOP_VERSION="3.4.1"
ASYNC_PROFILER_VERSION="2.9"

BUILDER_IMAGE="maven:3.9.9-eclipse-temurin-11"
RUNNER_IMAGE="eclipse-temurin:11-jre"

VCS_URL="https://github.com/PharosProduction/hdfs"
VCS_BRANCH="hdfs/master"
VCS_REF="40charsSHA-1hashOfCommit"

docker buildx stop
docker buildx create --use --name serverbuilder --node serverbuilder0 --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=1073741824

################################################################################

docker buildx build \
  --build-arg HADOOP_VERSION=$HADOOP_VERSION \
  --build-arg ASYNC_PROFILER_VERSION=$ASYNC_PROFILER_VERSION \
  --build-arg BUILDER_IMAGE=$BUILDER_IMAGE \
  --build-arg RUNNER_IMAGE=$RUNNER_IMAGE \
  --build-arg build_date=$DATE \
  --build-arg vcs_url=$VCS_URL \
  --build-arg vcs_branch=$VCS_BRANCH \
  --build-arg vcs_ref=$VCS_REF \
  --platform linux/arm64 \
  -f Dockerfile \
  --progress plain \
  --push \
  -t $ORGANIZATION/$DOCKER_REPO:$DATE-$VERSION \
  .

################################################################################

docker buildx stop