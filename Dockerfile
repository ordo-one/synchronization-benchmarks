FROM swift:latest

RUN apt-get update && apt-get install -y \
    libjemalloc-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mutex-bench
