################################################################################
# Stage 1: build Hadoop + native libs on ARM64
################################################################################
FROM maven:3.9.9-eclipse-temurin-11 AS builder

ARG HADOOP_VERSION=3.4.1
ENV HADOOP_HOME=/opt/hadoop

# 1) install all the headers/libs needed to compile native hadoop
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential cmake g++ automake libtool pkg-config \
    libsnappy-dev liblz4-dev libbz2-dev zlib1g-dev libssl-dev libfuse-dev \
    libprotobuf-dev protobuf-compiler libprotoc-dev \
    libcurl4-openssl-dev libboost-all-dev libsasl2-dev \
    libc6-dev libstdc++-12-dev libxml2-dev libkrb5-dev libtirpc-dev libnsl-dev \
  && rm -rf /var/lib/apt/lists/*

# 2) fetch Hadoop source bundle
WORKDIR /tmp
RUN wget https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}-src.tar.gz \
 && tar -xzf hadoop-${HADOOP_VERSION}-src.tar.gz

WORKDIR /tmp/hadoop-${HADOOP_VERSION}-src

# Fix 1: Add cstdint to uri.h
RUN sed -i '24i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/uri.h
# Fix 2: Add cstdint to statinfo.h
RUN sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/statinfo.h
# Fix 3: Add cstdint to fsinfo.h
RUN sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/fsinfo.h
# Fix 4: Add cstdint to content_summary.h
RUN sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/content_summary.h

# 3) build the dist + native libs, skipping tests and Javadoc
RUN mvn package \
        -Pdist,native \
        -DskipTests \
        -Dtar \
        -Djavadoc.skip=true \
        -Dmaven.javadoc.skip=true \
        -Dcmake.cpp.flags="-DCMAKE_CXX_STANDARD=11" \
        -e -X \
    && find hadoop-dist/target/hadoop-${HADOOP_VERSION}/bin -type f || echo "No binaries found in distribution"

# 4) assemble the finished binary into $HADOOP_HOME
RUN mkdir -p $HADOOP_HOME \
    && cp -r hadoop-dist/target/hadoop-${HADOOP_VERSION}/* $HADOOP_HOME

# 4) assemble the finished binary into $HADOOP_HOME
RUN mkdir -p $HADOOP_HOME \
    && cp -r hadoop-dist/target/hadoop-${HADOOP_VERSION}/* $HADOOP_HOME \
    && ls -l $HADOOP_HOME/bin/hdfs || (echo "hdfs binary missing in builder stage" && exit 1) \
    && $HADOOP_HOME/bin/hdfs version || (echo "hdfs binary not functional" && exit 1)

################################################################################
# Stage 2: runtime image (slim, with your ARM64 native libs)
################################################################################
FROM eclipse-temurin:11-jre

ARG HADOOP_VERSION=3.4.1
ENV HADOOP_HOME=/opt/hadoop
ENV HADOOP_COMMON_LIB_NATIVE_DIR=$HADOOP_HOME/lib/native
ENV LD_LIBRARY_PATH=$HADOOP_COMMON_LIB_NATIVE_DIR:$LD_LIBRARY_PATH
ENV PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH
ENV JAVA_TOOL_OPTIONS="-Djava.library.path=$HADOOP_COMMON_LIB_NATIVE_DIR"

# 5) install just the runtime decoder/crypto libs for your .so
RUN apt-get update && apt-get install --no-install-recommends -y \
      libsnappy1v5 liblz4-1 libbz2-1.0 zlib1g libssl3 \
       openssh-client openssh-server \
    && rm -rf /var/lib/apt/lists/*

# 6) copy in the Hadoop dist (including ARM64-native .so)
COPY --from=builder /opt/hadoop $HADOOP_HOME

# 7) sanity-check that libhadoop.so links correctly and hdfs binary exists
RUN ldd $HADOOP_COMMON_LIB_NATIVE_DIR/libhadoop.so \
    && ls -l $HADOOP_HOME/bin/hdfs || (echo "hdfs binary missing in runtime stage" && exit 1) \
    && chmod +x $HADOOP_HOME/bin/hdfs \
    && $HADOOP_HOME/bin/hdfs version || (echo "hdfs binary not functional" && exit 1)

# install async-profiler
ARG ASYNC_PROFILER_VERSION=2.9
RUN wget https://github.com/jvm-profiling-tools/async-profiler/releases/download/v${ASYNC_PROFILER_VERSION}/async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz \
    && tar -xzf async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz \
    && mv async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64 /opt/async-profiler \
    && rm async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz

# point Hadoop at async-profiler
ENV ASYNC_PROFILER_HOME=/opt/async-profiler
ENV JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Dasync.profiler.home=$ASYNC_PROFILER_HOME"

# SSH setup for Hadoop users
COPY conf/ssh_config /root/.ssh/config

# Set up users and SSH keys
RUN for user in hadoop hdfs yarn mapred; do \
        useradd -U -M -d /opt/hadoop/ --shell /bin/bash ${user}; \
    done && \
    for user in root hdfs yarn mapred; do \
        usermod -G hadoop ${user}; \
    done && \
    ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa && \
    cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
    chmod 0600 ~/.ssh/authorized_keys && \
    mkdir -p /var/hadoop/conf /var/hadoop/data /run/sshd

ENV WAIT_TIMEOUT_SECONDS=120

VOLUME /var/hadoop/conf
VOLUME /var/hadoop/data

# expose ports
EXPOSE 9820 9870 9864 9867

COPY conf/hadoop/* $HADOOP_CONF_DIR/
COPY scripts/ /scripts/
COPY *.sh /
RUN chmod +x /scripts/*.sh /*.sh

RUN useradd -m flink

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/healthcheck.sh"]
