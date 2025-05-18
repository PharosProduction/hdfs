ARG BUILDER_IMAGE="maven:3.9.9-eclipse-temurin-11"
ARG RUNNER_IMAGE="eclipse-temurin:11-jre"

################################################################################
# Stage 1: build Hadoop + native libs on ARM64, including async-profiler
################################################################################
FROM ${BUILDER_IMAGE} AS builder

ARG HADOOP_VERSION=3.4.1
ARG ASYNC_PROFILER_VERSION=2.9
ENV HADOOP_HOME=/opt/hadoop

# 1) install all the headers/libs needed to compile native Hadoop + wget
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential cmake g++ automake libtool pkg-config \
    libsnappy-dev liblz4-dev libbz2-dev zlib1g-dev libssl-dev libfuse-dev \
    libprotobuf-dev protobuf-compiler libprotoc-dev \
    libcurl4-openssl-dev libboost-all-dev libsasl2-dev \
    libc6-dev libstdc++-12-dev libxml2-dev libkrb5-dev libtirpc-dev libnsl-dev \
    wget \
 && rm -rf /var/lib/apt/lists/*

# 2) fetch Hadoop source bundle
WORKDIR /tmp
RUN wget https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/hadoop-${HADOOP_VERSION}-src.tar.gz \
 && tar -xzf hadoop-${HADOOP_VERSION}-src.tar.gz \
 && rm hadoop-${HADOOP_VERSION}-src.tar.gz

WORKDIR /tmp/hadoop-${HADOOP_VERSION}-src

# 3) fix headers for Hadoop build
RUN sed -i '24i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/uri.h \
 && sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/statinfo.h \
 && sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/fsinfo.h \
 && sed -i '21i#include <cstdint>' hadoop-hdfs-project/hadoop-hdfs-native-client/src/main/native/libhdfspp/include/hdfspp/content_summary.h

# 4) build Hadoop dist + native libs, skipping tests and Javadoc
RUN mvn package \
    -Pdist,native \
    -DskipTests \
    -Dtar \
    -Djavadoc.skip=true \
    -Dmaven.javadoc.skip=true \
    -Dcmake.cpp.flags="-DCMAKE_CXX_STANDARD=11" \
    -Drequire.snappy \
    -Drequire.zlib \
    -Drequire.openssl \
    -e -X \
 && find hadoop-dist/target/hadoop-${HADOOP_VERSION}/bin -type f || echo "No binaries found in distribution" \
 && ls -l hadoop-dist/target/hadoop-${HADOOP_VERSION}/bin/hdfs || echo "hdfs binary missing in build output"

# 5) assemble Hadoop binary into $HADOOP_HOME and verify hdfs
RUN mkdir -p $HADOOP_HOME \
 && cp -r hadoop-dist/target/hadoop-${HADOOP_VERSION}/* $HADOOP_HOME \
 && ls -l $HADOOP_HOME/bin/hdfs || (echo "hdfs binary missing in builder stage" && exit 1) \
 && $HADOOP_HOME/bin/hdfs version || (echo "hdfs binary not functional" && exit 1)

# 6) download and extract async-profiler
RUN wget https://github.com/jvm-profiling-tools/async-profiler/releases/download/v${ASYNC_PROFILER_VERSION}/async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz \
 && tar -xzf async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz \
 && mv async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64 /opt/async-profiler \
 && rm async-profiler-${ASYNC_PROFILER_VERSION}-linux-x64.tar.gz

################################################################################
# Stage 2: runtime image (slim, with ARM64 native libs)
################################################################################
FROM ${RUNNER_IMAGE} AS runner

ARG HADOOP_VERSION=3.4.1
ENV HADOOP_HOME=/opt/hadoop
ENV HADOOP_COMMON_LIB_NATIVE_DIR=$HADOOP_HOME/lib/native
ENV LD_LIBRARY_PATH=$HADOOP_COMMON_LIB_NATIVE_DIR:$LD_LIBRARY_PATH
ENV PATH=$HADOOP_HOME/bin:$HADOOP_HOME/sbin:$PATH
ENV JAVA_TOOL_OPTIONS="-Djava.library.path=$HADOOP_COMMON_LIB_NATIVE_DIR"

# 1) install minimal runtime dependencies
RUN apt-get update && apt-get install --no-install-recommends -y \
    openssh-client openssh-server \
 && rm -rf /var/lib/apt/lists/*

# 2) copy Hadoop dist and async-profiler from builder
COPY --from=builder /opt/hadoop $HADOOP_HOME
COPY --from=builder /opt/async-profiler /opt/async-profiler

# 3) sanity-check libhadoop.so and hdfs binary
RUN ldd $HADOOP_COMMON_LIB_NATIVE_DIR/libhadoop.so \
 && ls -l $HADOOP_HOME/bin/hdfs || (echo "hdfs binary missing in runtime stage" && exit 1) \
 && chmod +x $HADOOP_HOME/bin/hdfs \
 && $HADOOP_HOME/bin/hdfs version || (echo "hdfs binary not functional" && exit 1)

# 4) configure async-profiler
ENV ASYNC_PROFILER_HOME=/opt/async-profiler
ENV JAVA_TOOL_OPTIONS="$JAVA_TOOL_OPTIONS -Dasync.profiler.home=$ASYNC_PROFILER_HOME"

# 5) SSH setup for Hadoop users
COPY conf/ssh_config /root/.ssh/config
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

# 7) copy and configure scripts
COPY conf/hadoop/* $HADOOP_CONF_DIR/
COPY scripts/ /scripts/
COPY *.sh /
RUN chmod +x /scripts/*.sh /entrypoint.sh /healthcheck.sh

# 8) create flink user
RUN useradd -m flink

VOLUME /var/hadoop/conf /var/hadoop/data

# 6) expose ports
EXPOSE 9820 9870 9864 9867

HEALTHCHECK --interval=30s --timeout=10s --start-period=360s --retries=3 CMD /healthcheck.sh

# 9) set entrypoint and healthcheck
ENTRYPOINT ["/entrypoint.sh"]