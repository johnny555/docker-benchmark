# Use a common base image, like Ubuntu
FROM ubuntu:latest

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Update package lists and install sysbench and iperf3
RUN apt-get update && \
    apt-get install -y sysbench iperf3 && \
    # Clean up cache to keep image small
    rm -rf /var/lib/apt/lists/*
