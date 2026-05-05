FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV NDK_VERSION=r27c
ENV ANDROID_NDK_HOME=/opt/android-ndk
ENV PATH=${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64/bin:${PATH}

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates wget curl git unzip pkg-config autoconf \
    libssl-dev libffi-dev zlib1g-dev libsqlite3-dev libbz2-dev libreadline-dev \
    python3 python3-pip dpkg xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-linux.zip -O ndk.zip && \
    unzip -q ndk.zip -d /opt/ && rm ndk.zip && mv /opt/android-ndk-${NDK_VERSION} /opt/android-ndk
