# docker-benchmark

A small repo to contain scripts for benchmarking your docker. 

## Setup

Permissions: Ensure you can run Docker commands without sudo (i.e., your user is in the docker group). If not, you might need to add sudo before docker commands in the script or run the entire script with sudo.
Dependencies: Make sure sysbench, iperf3, docker, nproc, awk, grep, bc (for calculations) are installed on your host system.

`sudo apt update && sudo apt install -y sysbench iperf3 coreutils gawk bc`

Build docker image: 

`docker build -t sysbench-test .`

Run: 

`bash docker_benchmark.sh`

It will take several minutes to complete all tests.