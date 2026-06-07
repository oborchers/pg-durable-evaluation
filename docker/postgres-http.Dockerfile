ARG BASE_IMAGE=pg_durable_poc:latest
FROM ${BASE_IMAGE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends postgresql-17-http \
    && rm -rf /var/lib/apt/lists/*

