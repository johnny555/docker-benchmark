#!/bin/bash

# Exit on error
set -e
# Exit on pipe failures
set -o pipefail

# --- Configuration ---
NUM_RUNS=3
DOCKER_IMAGE="sysbench-test"
# CPU cores for multi-threaded tests (adjust if needed, nproc is usually good)
CPU_THREADS=$(nproc)
# Sysbench Test Parameters
CPU_MAX_PRIME=20000
MEM_TOTAL_SIZE="10G" # Reduced from 100G for faster runs, adjust if needed
MEM_BLOCK_SIZE="1M"  # Increased block size, often better for bandwidth
FILE_TOTAL_SIZE="2G"
FILE_THREADS=4
FILE_TEST_MODE="rndrw"
# Network Test Duration
IPERF_TIME=10
# Temporary directory for volume test data
TEST_VOL_DIR="./docker-vol-test-data"

# --- Helper Functions ---

# Check for required commands
check_command() {
  if ! command -v "$1" &> /dev/null; then
    echo "Error: Required command '$1' not found. Please install it."
    exit 1
  fi
}

# Function to parse sysbench CPU output for events/sec
parse_sysbench_cpu() {
  grep 'events per second:' | awk '{print $NF}'
}

# Function to parse sysbench Memory output for MiB/sec
parse_sysbench_mem() {
  # Target the line with "(<value> MiB/sec)" and extract the <value>
  grep 'MiB/sec)' | grep -Eo '[0-9]+\.[0-9]+ MiB/sec' | awk '{print $1}'
}
# Function to parse sysbench FileIO output
# Usage: parse_sysbench_fileio "metric_name"
# metric_name examples: "read, MiB/s:", "written, MiB/s:", "reads/s:", "writes/s:"
parse_sysbench_fileio() {
  local metric_name="$1"
  # Use awk for safer parsing, handling potential whitespace variations
  awk -v metric="$metric_name" '$0 ~ metric {print $NF}'
}

# Function to parse iperf3 output for Gbits/sec (handles Mbits too)
parse_iperf3() {
  # Get the summary line (sender or receiver, take the last one)
  local summary_line
  summary_line=$(grep -E 'receiver|sender' | tail -n1)
  if [[ -z "$summary_line" ]]; then
    echo "0" # Error parsing
    return
  fi

  local bitrate
  local unit
  # Extract the second-to-last field (value) and last field (unit)
  bitrate=$(echo "$summary_line" | awk '{print $(NF-1)}')
  unit=$(echo "$summary_line" | awk '{print $NF}')

  if [[ "$unit" == "Mbits/sec" ]]; then
    # Convert Mbits to Gbits using bc for floating point math
    echo $(bc <<< "scale=3; $bitrate / 1000")
  elif [[ "$unit" == "Gbits/sec" ]]; then
    echo "$bitrate"
  else
    echo "0" # Unknown unit or error
  fi
}

# Function to calculate average using bc
calculate_average() {
  local sum=$1
  local count=$2
  if [[ "$count" -eq 0 ]]; then
    echo "N/A"
  else
    echo $(bc <<< "scale=3; $sum / $count")
  fi
}

# --- Sanity Checks ---
echo "--- Performing Sanity Checks ---"
check_command docker
check_command sysbench
check_command iperf3
check_command nproc
check_command awk
check_command grep
check_command bc
check_command hostname

# Check Docker image
if ! docker image inspect "$DOCKER_IMAGE" > /dev/null 2>&1; then
   echo "Error: Docker image '$DOCKER_IMAGE' not found."
   echo "Please build it using the provided Dockerfile."
   exit 1
fi

# Get Host IP (use the first one found)
HOST_IP=$(hostname -I | awk '{print $1}')
if [[ -z "$HOST_IP" ]]; then
    echo "Error: Could not determine Host IP address."
    exit 1
fi
echo "Using Host IP: $HOST_IP for network tests."
echo "Using $CPU_THREADS threads for multi-threaded tests."
echo "Number of runs per test: $NUM_RUNS"
echo "--- Checks Complete ---"
echo ""

# --- Initialize Result Sums ---
declare -A sums
declare -A counts

# --- Benchmark Execution ---

# == CPU Benchmark ==
echo "--- Running CPU Benchmark ---"
for test_type in "Host" "Container"; do
  for threads in 1 $CPU_THREADS; do
    key="CPU_${test_type}_${threads}T"
    sums[$key]=0
    counts[$key]=0
    echo "Running $key tests..."
    for (( i=1; i<=$NUM_RUNS; i++ )); do
      echo "  Run $i/$NUM_RUNS..."
      result=
      if [[ "$test_type" == "Host" ]]; then
        result=$(sysbench cpu --threads=$threads --cpu-max-prime=$CPU_MAX_PRIME run | parse_sysbench_cpu)
      else
        result=$(docker run --rm "$DOCKER_IMAGE" sysbench cpu --threads=$threads --cpu-max-prime=$CPU_MAX_PRIME run | parse_sysbench_cpu)
      fi
      echo "    Result: $result events/sec"
      sums[$key]=$(bc <<< "${sums[$key]} + $result")
      counts[$key]=$(($i))
      sleep 1 # Small pause between runs
    done
  done
done
echo "--- CPU Benchmark Complete ---"
echo ""

# == Memory Benchmark ==
echo "--- Running Memory Benchmark ---"
for test_type in "Host" "Container"; do
  for threads in 1 $CPU_THREADS; do
    key="MEM_${test_type}_${threads}T"
    sums[$key]=0
    counts[$key]=0
    echo "Running $key tests..."
    for (( i=1; i<=$NUM_RUNS; i++ )); do
      echo "  Run $i/$NUM_RUNS..."
      result=
      if [[ "$test_type" == "Host" ]]; then
        result=$(sysbench memory --threads=$threads --memory-block-size=$MEM_BLOCK_SIZE --memory-total-size=$MEM_TOTAL_SIZE run | parse_sysbench_mem)
      else
        result=$(docker run --rm "$DOCKER_IMAGE" sysbench memory --threads=$threads --memory-block-size=$MEM_BLOCK_SIZE --memory-total-size=$MEM_TOTAL_SIZE run | parse_sysbench_mem)
      fi
      echo "    Result: $result MiB/sec"
      sums[$key]=$(bc <<< "${sums[$key]} + $result")
      counts[$key]=$(($i))
      sleep 1
    done
  done
done
echo "--- Memory Benchmark Complete ---"
echo ""

# == Disk I/O Benchmark ==
echo "--- Running Disk I/O Benchmark ---"
# Metrics to track for FileIO
fileio_metrics=("reads/s" "writes/s" "read, MiB/s:" "written, MiB/s:")
fileio_keys_suffix=("Reads" "Writes" "ReadMBps" "WriteMBps")

# Host Disk Test
echo "Running Disk Host tests..."
key_prefix="DISK_Host"
# Initialize sums/counts for host metrics
for suffix in "${fileio_keys_suffix[@]}"; do
  sums[${key_prefix}_${suffix}]=0
  counts[${key_prefix}_${suffix}]=0
done
sysbench fileio --file-total-size=$FILE_TOTAL_SIZE prepare > /dev/null 2>&1 # Prepare once
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
  output=$(sysbench fileio --file-total-size=$FILE_TOTAL_SIZE --file-test-mode=$FILE_TEST_MODE --threads=$FILE_THREADS --time=30 run) # Shorter time for script run
  echo "$output" > sysbench_fileio_host_run${i}.log # Log output for inspection if needed
  idx=0
  for metric in "${fileio_metrics[@]}"; do
      suffix=${fileio_keys_suffix[$idx]}
      result=$(echo "$output" | parse_sysbench_fileio "$metric")
      echo "    $metric $result"
      sums[${key_prefix}_${suffix}]=$(bc <<< "${sums[${key_prefix}_${suffix}]} + $result")
      counts[${key_prefix}_${suffix}]=$(($i))
      idx=$((idx + 1))
  done
   sleep 1
done
sysbench fileio --file-total-size=$FILE_TOTAL_SIZE cleanup > /dev/null 2>&1

# Container Internal Disk Test
echo "Running Disk Container (Internal) tests..."
key_prefix="DISK_ContainerInternal"
# Initialize sums/counts
for suffix in "${fileio_keys_suffix[@]}"; do
  sums[${key_prefix}_${suffix}]=0
  counts[${key_prefix}_${suffix}]=0
done
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
  output=$(docker run --rm "$DOCKER_IMAGE" \
            sh -c "sysbench fileio --file-total-size=$FILE_TOTAL_SIZE prepare > /dev/null 2>&1 && \
                   sysbench fileio --file-total-size=$FILE_TOTAL_SIZE --file-test-mode=$FILE_TEST_MODE --threads=$FILE_THREADS --time=30 run && \
                   sysbench fileio --file-total-size=$FILE_TOTAL_SIZE cleanup > /dev/null 2>&1")
  echo "$output" > sysbench_fileio_container_internal_run${i}.log
  idx=0
  for metric in "${fileio_metrics[@]}"; do
      suffix=${fileio_keys_suffix[$idx]}
      result=$(echo "$output" | parse_sysbench_fileio "$metric")
      echo "    $metric $result"
      sums[${key_prefix}_${suffix}]=$(bc <<< "${sums[${key_prefix}_${suffix}]} + $result")
      counts[${key_prefix}_${suffix}]=$(($i))
      idx=$((idx + 1))
  done
   sleep 1
done

# Container Volume Mount Disk Test
echo "Running Disk Container (Volume Mount) tests..."
mkdir -p "$TEST_VOL_DIR"
key_prefix="DISK_ContainerVolume"
# Initialize sums/counts
for suffix in "${fileio_keys_suffix[@]}"; do
  sums[${key_prefix}_${suffix}]=0
  counts[${key_prefix}_${suffix}]=0
done
docker run --rm -v "$(pwd)/$TEST_VOL_DIR:/test" "$DOCKER_IMAGE" sysbench fileio --file-total-size=$FILE_TOTAL_SIZE --file-dir=/test prepare > /dev/null 2>&1 # Prepare once
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
   output=$(docker run --rm -v "$(pwd)/$TEST_VOL_DIR:/test" "$DOCKER_IMAGE" sysbench fileio --file-total-size=$FILE_TOTAL_SIZE --file-dir=/test --file-test-mode=$FILE_TEST_MODE --threads=$FILE_THREADS --time=30 run)
   echo "$output" > sysbench_fileio_container_volume_run${i}.log
  idx=0
  for metric in "${fileio_metrics[@]}"; do
      suffix=${fileio_keys_suffix[$idx]}
      result=$(echo "$output" | parse_sysbench_fileio "$metric")
      echo "    $metric $result"
      sums[${key_prefix}_${suffix}]=$(bc <<< "${sums[${key_prefix}_${suffix}]} + $result")
      counts[${key_prefix}_${suffix}]=$(($i))
      idx=$((idx + 1))
  done
   sleep 1
done
docker run --rm -v "$(pwd)/$TEST_VOL_DIR:/test" "$DOCKER_IMAGE" sysbench fileio --file-total-size=$FILE_TOTAL_SIZE --file-dir=/test cleanup > /dev/null 2>&1
rm -rf "$TEST_VOL_DIR"

echo "--- Disk I/O Benchmark Complete ---"
echo ""


# == Network Benchmark ==
echo "--- Running Network Benchmark ---"
echo "Starting iperf3 server on host in background..."
iperf3 -s &
IPERF_PID=$!
# Ensure server is killed even if script exits unexpectedly
trap "echo 'Killing iperf3 server (PID $IPERF_PID)...'; kill $IPERF_PID &> /dev/null || true" EXIT
sleep 3 # Give server time to start

# Network Host Baseline (Host IP)
key="NET_Host"
sums[$key]=0
counts[$key]=0
echo "Running $key tests..."
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
  result=$(iperf3 -c $HOST_IP -t $IPERF_TIME | parse_iperf3)
  echo "    Result: $result Gbits/sec"
  sums[$key]=$(bc <<< "${sums[$key]} + $result")
  counts[$key]=$(($i))
  sleep 1
done

# Network Container (Bridge)
key="NET_ContainerBridge"
sums[$key]=0
counts[$key]=0
echo "Running $key tests..."
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
  result=$(docker run --rm "$DOCKER_IMAGE" iperf3 -c $HOST_IP -t $IPERF_TIME | parse_iperf3)
  echo "    Result: $result Gbits/sec"
  sums[$key]=$(bc <<< "${sums[$key]} + $result")
  counts[$key]=$(($i))
  sleep 1
done

# Network Container (Host Network)
key="NET_ContainerHost"
sums[$key]=0
counts[$key]=0
echo "Running $key tests..."
for (( i=1; i<=$NUM_RUNS; i++ )); do
  echo "  Run $i/$NUM_RUNS..."
  # When using host network, connect to loopback or host IP from container perspective
  result=$(docker run --rm --network host "$DOCKER_IMAGE" iperf3 -c 127.0.0.1 -t $IPERF_TIME | parse_iperf3)
  echo "    Result: $result Gbits/sec"
  sums[$key]=$(bc <<< "${sums[$key]} + $result")
  counts[$key]=$(($i))
  sleep 1
done

echo "Stopping iperf3 server..."
kill $IPERF_PID
# Clean up trap
trap - EXIT
wait $IPERF_PID 2>/dev/null || true # Wait for server to exit, ignore errors if already gone
echo "--- Network Benchmark Complete ---"
echo ""


# --- Display Results ---
echo "========== BENCHMARK RESULTS (AVERAGES OVER $NUM_RUNS RUNS) =========="
echo ""
echo "--- CPU (events/sec, higher is better) ---"
printf "%-25s : %s\n" "Host (1T)" "$(calculate_average "${sums[CPU_Host_1T]}" "${counts[CPU_Host_1T]}")"
printf "%-25s : %s\n" "Container (1T)" "$(calculate_average "${sums[CPU_Container_1T]}" "${counts[CPU_Container_1T]}")"
printf "%-25s : %s\n" "Host (${CPU_THREADS}T)" "$(calculate_average "${sums[CPU_Host_${CPU_THREADS}T]}" "${counts[CPU_Host_${CPU_THREADS}T]}")"
printf "%-25s : %s\n" "Container (${CPU_THREADS}T)" "$(calculate_average "${sums[CPU_Container_${CPU_THREADS}T]}" "${counts[CPU_Container_${CPU_THREADS}T]}")"
echo ""

echo "--- Memory (MiB/sec, higher is better) ---"
printf "%-25s : %s\n" "Host (1T)" "$(calculate_average "${sums[MEM_Host_1T]}" "${counts[MEM_Host_1T]}")"
printf "%-25s : %s\n" "Container (1T)" "$(calculate_average "${sums[MEM_Container_1T]}" "${counts[MEM_Container_1T]}")"
printf "%-25s : %s\n" "Host (${CPU_THREADS}T)" "$(calculate_average "${sums[MEM_Host_${CPU_THREADS}T]}" "${counts[MEM_Host_${CPU_THREADS}T]}")"
printf "%-25s : %s\n" "Container (${CPU_THREADS}T)" "$(calculate_average "${sums[MEM_Container_${CPU_THREADS}T]}" "${counts[MEM_Container_${CPU_THREADS}T]}")"
echo ""

echo "--- Disk I/O (${FILE_TEST_MODE}, higher is better) ---"
printf "%-25s | %-12s | %-12s | %-12s | %-12s\n" "Scenario" "Reads/s" "Writes/s" "Read MiB/s" "Write MiB/s"
printf "%-25s-+-%-12s-+-%-12s-+-%-12s-+-%-12s\n" "-------------------------" "------------" "------------" "------------" "------------"
printf "%-25s | %-12s | %-12s | %-12s | %-12s\n" "Host" \
  "$(calculate_average "${sums[DISK_Host_Reads]}" "${counts[DISK_Host_Reads]}")" \
  "$(calculate_average "${sums[DISK_Host_Writes]}" "${counts[DISK_Host_Writes]}")" \
  "$(calculate_average "${sums[DISK_Host_ReadMBps]}" "${counts[DISK_Host_ReadMBps]}")" \
  "$(calculate_average "${sums[DISK_Host_WriteMBps]}" "${counts[DISK_Host_WriteMBps]}")"
printf "%-25s | %-12s | %-12s | %-12s | %-12s\n" "Container (Internal)" \
  "$(calculate_average "${sums[DISK_ContainerInternal_Reads]}" "${counts[DISK_ContainerInternal_Reads]}")" \
  "$(calculate_average "${sums[DISK_ContainerInternal_Writes]}" "${counts[DISK_ContainerInternal_Writes]}")" \
  "$(calculate_average "${sums[DISK_ContainerInternal_ReadMBps]}" "${counts[DISK_ContainerInternal_ReadMBps]}")" \
  "$(calculate_average "${sums[DISK_ContainerInternal_WriteMBps]}" "${counts[DISK_ContainerInternal_WriteMBps]}")"
printf "%-25s | %-12s | %-12s | %-12s | %-12s\n" "Container (Volume Mount)" \
  "$(calculate_average "${sums[DISK_ContainerVolume_Reads]}" "${counts[DISK_ContainerVolume_Reads]}")" \
  "$(calculate_average "${sums[DISK_ContainerVolume_Writes]}" "${counts[DISK_ContainerVolume_Writes]}")" \
  "$(calculate_average "${sums[DISK_ContainerVolume_ReadMBps]}" "${counts[DISK_ContainerVolume_ReadMBps]}")" \
  "$(calculate_average "${sums[DISK_ContainerVolume_WriteMBps]}" "${counts[DISK_ContainerVolume_WriteMBps]}")"
echo ""

echo "--- Network (Gbits/sec, higher is better) ---"
printf "%-25s : %s\n" "Host -> Host (IP)" "$(calculate_average "${sums[NET_Host]}" "${counts[NET_Host]}")"
printf "%-25s : %s\n" "Container (Bridge) -> Host" "$(calculate_average "${sums[NET_ContainerBridge]}" "${counts[NET_ContainerBridge]}")"
printf "%-25s : %s\n" "Container (Host Net) -> Host" "$(calculate_average "${sums[NET_ContainerHost]}" "${counts[NET_ContainerHost]}")"
echo ""

echo "========== BENCHMARK COMPLETE =========="

# Clean up log files (optional)
# rm -f sysbench_*.log

exit 0
