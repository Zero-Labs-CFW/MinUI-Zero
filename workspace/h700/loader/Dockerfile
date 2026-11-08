FROM debian@sha256:d74df7598108a173a621eda4d58a2adbf850b2d9a9d81bc2cca1a6c21174a880
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gcc=4:12.2.0-3 binutils=2.40-2 make=4.3-4.1 python3=3.11.2-1+b1 \
    libc6-dev=2.36-9+deb12u14 device-tree-compiler=1.6.1-4+b1 zlib1g-dev=1:1.2.13.dfsg-1 \
    ca-certificates >/dev/null && rm -rf /var/lib/apt/lists/*
