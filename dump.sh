#!/usr/bin/env bash

set -euo pipefail
set -Eo functrace

# Global variable for quiet mode
QUIET_MODE="false"

# Global variable for cluster-wide data collection
COLLECT_CLUSTER_DATA="true"

function dump::__failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}
trap 'dump::__failure ${LINENO} "$BASH_COMMAND"' ERR

function dump::__print_status() {
    if [[ "$QUIET_MODE" != "true" ]]; then
        echo -e "$@"
    fi
}

function dump::__validate_bool() {
    local value="$1"
    case "$value" in
        true|false)
            echo "$value"
            ;;
        *)
            echo "Error: Invalid boolean value '$value'. Use 'true' or 'false'." >&2
            exit 1
            ;;
    esac
}



function dump::__print_usage() {
    cat << EOF

Usage: kubectl kedify dump [options]

Collects comprehensive diagnostic information from Kedify/KEDA components including:
- Cluster-wide information (nodes, autoscaler data, resource allocation)
- Namespace-specific data (events, scaling resources, pod logs)
- Kedify/KEDA component configurations and status

Options:
  -o, --output DIR                  Output directory or archive file path (default: current directory)
  -n, --namespace NS                Specific namespace (default: current namespace)  
  -A, --all-namespaces              Collect from all namespaces
  -q, --quiet                       Quiet mode - suppress all status output
  -a, --archive                     Create tar.gz archive
  -c, --collect-cluster-data=BOOL   Collect cluster-wide data (default: true)

  -h, --help               Show this help message

Examples:
  kubectl kedify dump                               ... collect diagnostic info from current namespace
  kubectl kedify dump -n myapp                      ... collect diagnostic info from 'myapp' namespace
  kubectl kedify dump -A                            ... collect diagnostic info from all namespaces
  kubectl kedify dump -q                            ... collect diagnostic info quietly (no status messages)
  kubectl kedify dump -o /tmp/data                  ... collect diagnostic info to '/tmp/data' directory
  kubectl kedify dump -o data.tar.gz -a             ... collect diagnostic info and store in 'data.tar.gz' archive
  kubectl kedify dump -c=false                      ... don't collect diagnostic info without cluster-wide data
  kubectl kedify dump --collect-cluster-data=false  ... don't collect diagnostic info without cluster-wide data

EOF
}

function dump::__structured_output() {
    cat << EOF
jq -s '
  group_by(.namespace, .name) |
  map({
    namespace: .[0].namespace,
    name: .[0].name,
    triggers: map({
      triggerName: .triggerName,
      triggerType: .triggerType,
      metric: .metric,
      value: .value
  })
})
'
EOF
}

function dump::__cleanup_port_forwards() {
    local pids=("$@")
    if [[ ${#pids[@]} -gt 0 ]]; then
        for pid in "${pids[@]}"; do
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
        set -m 2>/dev/null || true  # Re-enable job control
    fi
}

function dump::__wait_for_port_forwards() {
    local ports=("$@")
    local max_wait=30
    
    dump::__print_status "  \033[36m- Waiting for port-forwards to be ready...\033[0m"
    
    for port in "${ports[@]}"; do
        local ready=false
        local port_wait=0
        while [[ $port_wait -lt $max_wait ]] && [[ "$ready" == "false" ]]; do
            # Try to connect to the port using curl with a very short timeout
            if curl -s --max-time 1 --connect-timeout 1 "http://localhost:${port}/ready" >/dev/null 2>&1 || \
               curl -s --max-time 1 --connect-timeout 1 "http://localhost:${port}/" >/dev/null 2>&1; then
                ready=true
            else
                sleep 0.5
                port_wait=$((port_wait + 1))
            fi
        done
        
        if [[ "$ready" == "false" ]]; then
            dump::__print_status "    \033[31m⚠ Warning: Port $port not ready after ${max_wait}s, proceeding anyway\033[0m"
        fi
    done
}

function dump::__aggregate_interceptor_queue() {
    local output_format="$1"
    local mode="$2"

    local cmd=""
    case $output_format in
        json)
            cmd="jq '.'"
            ;;
        yaml)
            cmd="yq e -P"
            ;;
        *)
            cmd="$(dump::__addon_queue_structured_output $mode) | column -t -s $'\t'"
            ;;            
    esac
    jq -n --arg mode "$mode" '
      if $mode == "aggregated" then
        # Aggregate all queues (original behavior)
        reduce inputs as $in ({};
          reduce ($in.queue | to_entries[]) as $entry (.;
            .[$entry.key] as $existing |
            if $existing then
              .[$entry.key] = (
                $existing |
                with_entries(
                  .value as $v |
                  $entry.value[.key] as $new_val |
                  if $new_val then
                    .value = ($v + $new_val)
                  else
                    .
                  end
                )
              )
            else
              .[$entry.key] = $entry.value
            end
          )
        )
      else
        # Individual mode: preserve pod names
        [inputs | {pod: .name, queue: .queue}]
      end
    ' | eval "$cmd"
}

function dump::__addon_queue_structured_output() {
    local mode="$1"
    if [ "$mode" = "individual" ]; then
        cat <<'EOF'
jq -r '
(["POD", "TARGET", "CONCURRENCY", "RPS"],
 (.[] | [
    .pod,
    (.queue | keys[0]),
    .queue[.queue | keys[0]].Concurrency,
    .queue[.queue | keys[0]].RPS
 ]))
 | @tsv'
EOF
    else
        cat <<'EOF'
jq -r '
(["TARGET", "CONCURRENCY", "RPS"],
 (to_entries[] | [
    .key,
    .value.Concurrency,
    .value.RPS
 ]))
 | @tsv'
EOF
    fi
}

function dump::__collect_http_addon_queue_data() {
    local ns="$1"
    local ns_dir="$2"
    local output_format="$3"
    local mode="$4"
    local output_file="$5"
    local error_msg="$6"
    
    # If no output_file is provided, output to stdout (for debug command)
    local output_to_file=false
    if [[ -n "$output_file" ]]; then
        output_to_file=true
    fi
    
    # Array to track port-forward PIDs for cleanup
    local pids=()
    
    # Set up trap to cleanup port-forwards if interrupted
    trap 'if [[ ${#pids[@]} -gt 0 ]]; then dump::__cleanup_port_forwards "${pids[@]}"; fi' INT TERM EXIT
    
    # Collect HTTP addon queue data from interceptor pods using port forwarding
    local function_output=""
    function_output=$(
        # Only show headers and messages for dump command (when output_to_file is true)
        if [[ "$output_to_file" == "true" ]]; then
            if [[ "$output_format" == "json" ]]; then
                # For JSON format, just output the data without headers
                :
            else
                echo "# HTTP Add-on Queue Data (mode: $mode, format: $output_format)"
                echo "# Collected at: $(date)"
                echo ""
            fi
        fi
        
        # Get interceptor pods
        local interceptor_pods
        IFS=$'\n' read -d '' -r -a interceptor_pods < <(kubectl get pods -l app.kubernetes.io/name=http-add-on -l app.kubernetes.io/component=interceptor -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' && printf '\0')
        
        if [[ ${#interceptor_pods[@]} -gt 0 ]]; then
            # Set up port forwards for interceptor pods (they typically expose metrics on port 9090)
            set +m  # Disable job control to suppress messages
            local local_port=9090
            local forward_ports=()
            
            for pod in "${interceptor_pods[@]}"; do
                local_port=$((local_port + 1))
                # Try common HTTP add-on interceptor ports: 9090 (metrics), 8080 (main), 9091 (admin)
                local pod_ports=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.containers[*].ports[*].containerPort}' 2>/dev/null)
                local target_port=""
                
                # Check if pod has port 9090 (metrics/queue endpoint)
                if echo "$pod_ports" | grep -q "9090"; then
                    target_port="9090"
                elif echo "$pod_ports" | grep -q "8080"; then
                    target_port="8080"
                elif echo "$pod_ports" | grep -q "9091"; then
                    target_port="9091"
                else
                    # Default to 9090 if we can't determine the port
                    target_port="9090"
                fi
                
                kubectl port-forward -n "$ns" "$pod" "$local_port:$target_port" >/dev/null 2>&1 &
                pids+=($!)
                forward_ports+=("$local_port")
            done
            
            # Wait for port forwards to be ready
            if [[ "$output_to_file" == "true" && "$output_format" != "json" ]]; then
                echo "# Waiting for port-forwards to interceptor pods..."
            fi
            local max_wait=30
            for port in "${forward_ports[@]}"; do
                local ready=false
                local port_wait=0
                while [[ $port_wait -lt $max_wait ]] && [[ "$ready" == "false" ]]; do
                    # Try different endpoints that might be available
                    if curl -s --max-time 1 --connect-timeout 1 "http://localhost:${port}/queue" >/dev/null 2>&1 || \
                       curl -s --max-time 1 --connect-timeout 1 "http://localhost:${port}/metrics" >/dev/null 2>&1 || \
                       curl -s --max-time 1 --connect-timeout 1 "http://localhost:${port}/" >/dev/null 2>&1; then
                        ready=true
                    else
                        sleep 0.5
                        port_wait=$((port_wait + 1))
                    fi
                done
                
                if [[ "$ready" == "false" && "$output_to_file" == "true" && "$output_format" != "json" ]]; then
                    echo "# Warning: Port $port not ready after ${max_wait}s, proceeding anyway"
                fi
            done
            
            # Collect queue data and format it properly
            local queue_json_data=""
            local_port=9090
            for pod in "${interceptor_pods[@]}"; do
                local_port=$((local_port + 1))
                
                # Try to get queue data from different possible endpoints
                local queue_data=""
                for endpoint in "/queue" "/api/v1/queue" "/metrics" ""; do
                    if queue_data=$(curl -s --max-time 5 "http://localhost:${local_port}${endpoint}" 2>/dev/null); then
                        if [[ -n "$queue_data" ]]; then
                            # If we got data from /metrics, try to filter for queue-related metrics
                            if [[ "$endpoint" == "/metrics" ]]; then
                                # Try to parse queue metrics from prometheus format
                                # This is a fallback - queue endpoint is preferred
                                continue
                            else
                                # We got queue data, format it as JSON for processing
                                queue_json_data+=$(echo "$queue_data" | jq -r '. | {name: "'$pod'", queue: .}')$'\n'
                                break
                            fi
                        fi
                    fi
                done
                
                if [[ -z "$queue_data" && "$output_to_file" == "true" && "$output_format" != "json" ]]; then
                    echo "# Failed to get queue data from $pod (tried endpoints: /queue, /api/v1/queue, /metrics, /)"
                fi
            done
            
            # Process and format the collected data
            if [[ -n "$queue_json_data" ]]; then
                echo "$queue_json_data" | dump::__aggregate_interceptor_queue "$output_format" "$mode"
            else
                if [[ "$output_format" == "json" ]]; then
                    if [[ "$mode" == "individual" ]]; then
                        echo "[]"
                    else
                        echo "{}"
                    fi
                else
                    if [[ "$output_to_file" == "true" ]]; then
                        echo "# No queue data could be retrieved from interceptor pods"
                    else
                        # For debug command, output appropriate empty result
                        if [[ "$output_format" == "json" ]]; then
                            if [[ "$mode" == "individual" ]]; then
                                echo "[]"
                            else
                                echo "{}"
                            fi
                        else
                            echo "No queue data available"
                        fi
                    fi
                fi
            fi
            
            # Cleanup port forwards
            dump::__cleanup_port_forwards "${pids[@]}"
            pids=()
            set -m 2>/dev/null || true  # Re-enable job control
        else
            if [[ "$output_format" == "json" ]]; then
                if [[ "$mode" == "individual" ]]; then
                    echo "[]"
                else
                    echo "{}"
                fi
            else
                if [[ "$output_to_file" == "true" ]]; then
                    echo "# No HTTP Add-on interceptor pods found in namespace $ns"
                else
                    echo "No HTTP Add-on interceptor pods found"
                fi
            fi
        fi
    )
    
    # Output to file or stdout based on whether output_file was provided
    if [[ "$output_to_file" == "true" ]]; then
        echo "$function_output" > "${ns_dir}/${output_file}" 2>/dev/null || dump::__print_status "    \033[31m${error_msg}\033[0m"
    else
        echo "$function_output"
    fi
    
    # Clear the trap as we're ending the function normally
    trap - INT TERM EXIT
}

function dump::__collect_namespace_data() {
    local ns="$1"
    local base_dir="$2"
    local is_installation_ns="$3"
    
    local ns_dir="${base_dir}/${ns}"
    mkdir -p "$ns_dir"
    
    # Array to track port-forward PIDs for cleanup on interruption
    local pids=()
    
    # Set up trap to cleanup port-forwards if the script is interrupted
    trap 'if [[ ${#pids[@]} -gt 0 ]]; then dump::__cleanup_port_forwards "${pids[@]}"; fi' INT TERM EXIT
    
    dump::__print_status "\033[33m=== Processing Namespace: $ns ===\033[0m"
    
    # Collect Kubernetes events for this namespace
    dump::__print_status "\033[36mCollecting Kubernetes events...\033[0m"
    if kubectl get events -n "$ns" --sort-by='.lastTimestamp' -o yaml > "${ns_dir}/events.yaml" 2>/dev/null; then
        dump::__print_status "  \033[32m✓ Events collected\033[0m"
    else
        dump::__print_status "  \033[31m✗ Failed to collect events\033[0m"
    fi
    
    # Get kedify-proxy pods and collect their data
    local pods
    IFS=$'\n' read -d '' -r -a pods < <(kubectl get pods -n "$ns" -l app=kedify-proxy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' && printf '\0')
    
    if [[ ${#pods[@]} -gt 0 ]]; then
        dump::__print_status "\033[36mCollecting kedify-proxy data...\033[0m"
        dump::__print_status "  \033[90mFound ${#pods[@]} kedify-proxy pod(s)\033[0m"
        
        # Set up port forwards (disable job control to suppress messages)
        set +m
        local local_port=9901
        local forward_ports=()
        for pod in "${pods[@]}"; do
            local_port=$((local_port + 1))
            kubectl port-forward -n "$ns" "$pod" $local_port:9901 >/dev/null 2>&1 &
            pids+=($!)
            forward_ports+=("$local_port")
        done
        
        # Wait for port forwards to be ready
        dump::__wait_for_port_forwards "${forward_ports[@]}"
        
        # Collect data from each kedify-proxy pod
        local_port=9901
        for pod in "${pods[@]}"; do
            dump::__print_status "  \033[36m- Collecting envoy data from:\033[0m $pod"
            local_port=$((local_port + 1))
            
            # Pod manifest and description
            kubectl get pod -n "$ns" "$pod" -o yaml > "${ns_dir}/${pod}-pod.yaml" 2>/dev/null || dump::__print_status "    \033[31mFailed to get pod YAML for $pod\033[0m"
            kubectl describe pod -n "$ns" "$pod" > "${ns_dir}/${pod}-pod.describe.txt" 2>/dev/null || dump::__print_status "    \033[31mFailed to describe pod $pod\033[0m"
            
            # Pod logs
            kubectl logs -n "$ns" "$pod" > "${ns_dir}/${pod}-logs.txt" 2>/dev/null || dump::__print_status "    \033[31mFailed to get logs for $pod\033[0m"
            
            # Envoy config dump
            for i in {1..5}; do
                if curl -s --max-time 5 "http://localhost:${local_port}/config_dump" -o "${ns_dir}/${pod}-config_dump.json" 2>/dev/null; then
                    dump::__print_status "    \033[32m✓ Config dump collected\033[0m"
                    break
                fi
                sleep 1
            done
            
            # Envoy metrics
            for i in {1..5}; do
                if curl -s --max-time 5 "http://localhost:${local_port}/stats/prometheus" -o "${ns_dir}/${pod}-prometheus.txt" 2>/dev/null; then
                    dump::__print_status "    \033[32m✓ Prometheus metrics collected\033[0m"
                    break
                fi
                sleep 1
            done
            
            # Envoy clusters information
            for i in {1..5}; do
                if curl -s --max-time 5 "http://localhost:${local_port}/clusters?format=json" -o "${ns_dir}/${pod}-clusters.json" 2>/dev/null; then
                    dump::__print_status "    \033[32m✓ Envoy clusters information collected\033[0m"
                    break
                fi
                sleep 1
            done
        done
        
        # Collect resource usage for all kedify-proxy pods in this namespace
        dump::__print_status "  \033[36m- Collecting resource usage for kedify-proxy pods...\033[0m"
        if kubectl top pod -n "$ns" -l app=kedify-proxy --no-headers 2>/dev/null > "${ns_dir}/kedify-proxy-pods-resource-usage.txt"; then
            dump::__print_status "    \033[32m✓ Resource usage collected\033[0m"
        else
            dump::__print_status "    \033[31m✗ Failed to get resource usage (metrics-server may not be available)\033[0m"
        fi
        
        # Cleanup port forwards (suppress job control messages)
        dump::__cleanup_port_forwards "${pids[@]}"
        pids=()  # Clear the pids array
        sleep 1  # Brief pause to ensure cleanup is complete
    fi
    
    # Collect ScaledObjects, HPAs, ScaledJobs, HTTPScaledObjects, and Kedify resources from this namespace
    dump::__print_status "\033[36mCollecting scaling resources...\033[0m"
    
    # ScaledObjects (only if CRD exists)
    if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
        local so_check=$(kubectl get scaledobjects -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$so_check" ]]; then
            kubectl get scaledobjects -n "$ns" -o yaml > "${ns_dir}/scaledobjects.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ ScaledObjects collected\033[0m"
        else
            dump::__print_status "  \033[90m- No ScaledObjects found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- ScaledObjects CRD not available (KEDA not installed)\033[0m"
    fi
    
    # HPAs
    local hpa_check=$(kubectl get hpa -n "$ns" --no-headers 2>/dev/null)
    if [[ -n "$hpa_check" ]]; then
        kubectl get hpa -n "$ns" -o yaml > "${ns_dir}/hpa.yaml" 2>/dev/null
        dump::__print_status "  \033[32m✓ HPAs collected\033[0m"
    else
        dump::__print_status "  \033[90m- No HPAs found\033[0m"
    fi
    
    # ScaledJobs (only if CRD exists)
    if kubectl get crd scaledjobs.keda.sh >/dev/null 2>&1; then
        local sj_check=$(kubectl get scaledjobs -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$sj_check" ]]; then
            kubectl get scaledjobs -n "$ns" -o yaml > "${ns_dir}/scaledjobs.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ ScaledJobs collected\033[0m"
        else
            dump::__print_status "  \033[90m- No ScaledJobs found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- ScaledJobs CRD not available (KEDA not installed)\033[0m"
    fi
    
    # HTTPScaledObjects (only if CRD exists)
    if kubectl get crd httpscaledobjects.http.keda.sh >/dev/null 2>&1; then
        local hso_check=$(kubectl get httpscaledobjects -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$hso_check" ]]; then
            kubectl get httpscaledobjects -n "$ns" -o yaml > "${ns_dir}/httpscaledobjects.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ HTTPScaledObjects collected\033[0m"
            
            # Collect services referenced by HTTPScaledObjects
            dump::__print_status "  \033[36m- Collecting services referenced by HTTPScaledObjects...\033[0m"
            local services_yaml="${ns_dir}/httpscaledobjects-services.yaml"
            local services_found=false
            
            # Get all HTTPScaledObject names that have service references
            local hso_names=()
            while IFS= read -r hso_name; do
                [[ -n "$hso_name" ]] && hso_names+=("$hso_name")
            done < <(kubectl get httpscaledobjects -n "$ns" -o json 2>/dev/null | jq -r '.items[] | select(.spec.scaleTargetRef.service != null or .metadata.annotations["http.kedify.io/fallback-service"] != null) | .metadata.name')
            
            if [[ ${#hso_names[@]} -gt 0 ]]; then
                # Start the services YAML file
                echo "# Services referenced by HTTPScaledObjects in namespace: $ns" > "$services_yaml"
                echo "# Generated: $(date)" >> "$services_yaml"
                echo "---" >> "$services_yaml"
                
                for hso_name in "${hso_names[@]}"; do
                    # Get the HTTPScaledObject details
                    local hso_json=$(kubectl get httpscaledobject "$hso_name" -n "$ns" -o json 2>/dev/null)
                    
                    # Extract service names
                    local target_service=$(echo "$hso_json" | jq -r '.spec.scaleTargetRef.service // empty')
                    local fallback_service=$(echo "$hso_json" | jq -r '.metadata.annotations["http.kedify.io/fallback-service"] // empty')
                    
                    local hso_services_found=false
                    
                    # Collect target service
                    if [[ -n "$target_service" ]]; then
                        if kubectl get service "$target_service" -n "$ns" >/dev/null 2>&1; then
                            echo "# HTTPScaledObject: $hso_name - Target service: $target_service" >> "$services_yaml"
                            kubectl get service "$target_service" -n "$ns" -o yaml >> "$services_yaml" 2>/dev/null
                            echo "---" >> "$services_yaml"
                            hso_services_found=true
                            services_found=true
                        fi
                    fi
                    
                    # Collect fallback service
                    if [[ -n "$fallback_service" ]]; then
                        if kubectl get service "$fallback_service" -n "$ns" >/dev/null 2>&1; then
                            echo "# HTTPScaledObject: $hso_name - Fallback service: $fallback_service" >> "$services_yaml"
                            kubectl get service "$fallback_service" -n "$ns" -o yaml >> "$services_yaml" 2>/dev/null
                            echo "---" >> "$services_yaml"
                            hso_services_found=true
                            services_found=true
                        fi
                    fi
                    
                    if [[ "$hso_services_found" == "true" ]]; then
                        dump::__print_status "    \033[32m✓ Services for HTTPScaledObject '$hso_name' collected\033[0m"
                    else
                        dump::__print_status "    \033[90m- No services found for HTTPScaledObject '$hso_name'\033[0m"
                    fi
                done
            fi
            
            if [[ "$services_found" == "false" ]]; then
                rm -f "$services_yaml"
                dump::__print_status "    \033[90m- No services found for any HTTPScaledObjects\033[0m"
            fi
        else
            dump::__print_status "  \033[90m- No HTTPScaledObjects found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- HTTPScaledObjects CRD not available (HTTP Add-on not installed)\033[0m"
    fi
    
    # PodResourceProfiles (only if CRD exists)
    if kubectl get crd podresourceprofiles.keda.kedify.io >/dev/null 2>&1; then
        local prp_check=$(kubectl get podresourceprofiles -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$prp_check" ]]; then
            kubectl get podresourceprofiles -n "$ns" -o yaml > "${ns_dir}/podresourceprofiles.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ PodResourceProfiles collected\033[0m"
        else
            dump::__print_status "  \033[90m- No PodResourceProfiles found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- PodResourceProfiles CRD not available (Kedify not installed)\033[0m"
    fi
    
    # ScalingGroups (only if CRD exists)
    if kubectl get crd scalinggroups.keda.kedify.io >/dev/null 2>&1; then
        local sg_check=$(kubectl get scalinggroups -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$sg_check" ]]; then
            kubectl get scalinggroups -n "$ns" -o yaml > "${ns_dir}/scalinggroups.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ ScalingGroups collected\033[0m"
        else
            dump::__print_status "  \033[90m- No ScalingGroups found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- ScalingGroups CRD not available (Kedify not installed)\033[0m"
    fi
    
    # ScalingPolicies (only if CRD exists)
    if kubectl get crd scalingpolicies.keda.kedify.io >/dev/null 2>&1; then
        local sp_check=$(kubectl get scalingpolicies -n "$ns" --no-headers 2>/dev/null)
        if [[ -n "$sp_check" ]]; then
            kubectl get scalingpolicies -n "$ns" -o yaml > "${ns_dir}/scalingpolicies.yaml" 2>/dev/null
            dump::__print_status "  \033[32m✓ ScalingPolicies collected\033[0m"
        else
            dump::__print_status "  \033[90m- No ScalingPolicies found\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- ScalingPolicies CRD not available (Kedify not installed)\033[0m"
    fi
    
    # Collect Kedify OTel Add-on data if available (can be installed per namespace)
    dump::__print_status "\033[36mCollecting Kedify OTel Add-on data...\033[0m"
    
    # Check for OTel Helm release secrets in this namespace
    local otel_helm_found=false
    local otel_patterns=("sh.helm.release.v1.kedify-otel.v*" "sh.helm.release.v1.keda-otel-scaler.v*")
    for pattern in "${otel_patterns[@]}"; do
        while IFS= read -r secret_name; do
            if [[ -n "$secret_name" ]]; then
                if dump::__extract_helm_release_data "$ns" "$secret_name" "$ns_dir" "helm-"; then
                    otel_helm_found=true
                fi
            fi
        done < <(kubectl get secrets -n "$ns" -o name 2>/dev/null | grep -E "^secret/${pattern//\*/.*}$" | sed 's|^secret/||' || true)
    done
    
    # Collect OTel scaler service data if keda-otel-scaler service exists
    if kubectl get service keda-otel-scaler -n "$ns" >/dev/null 2>&1; then
        dump::__print_status "  \033[36m- Found keda-otel-scaler service, collecting metrics and memstore data...\033[0m"
        
        # Set up port forwards for OTel scaler service
        set +m  # Disable job control to suppress messages
        local otel_pids=()
        
        # Port forward for metrics (8080)
        kubectl port-forward -n "$ns" svc/keda-otel-scaler 8080:8080 >/dev/null 2>&1 &
        local metrics_pid=$!
        otel_pids+=("$metrics_pid")
        
        # Port forward for memstore data (9090)
        kubectl port-forward -n "$ns" svc/keda-otel-scaler 9090:9090 >/dev/null 2>&1 &
        local memstore_pid=$!
        otel_pids+=("$memstore_pid")
        
        # Wait a moment for port forwards to be ready
        sleep 3
        
        # Collect metrics
        if curl -s --max-time 10 "http://localhost:8080/metrics" -o "${ns_dir}/kedify-otel-scaler-metrics.txt" 2>/dev/null; then
            dump::__print_status "    \033[32m✓ OTel scaler metrics collected\033[0m"
        else
            dump::__print_status "    \033[31m✗ Failed to collect OTel scaler metrics\033[0m"
        fi
        
        # Collect memstore data
        if curl -s --max-time 10 "http://localhost:9090/memstore/data" -o "${ns_dir}/kedify-otel-scaler-memstore.json" 2>/dev/null; then
            dump::__print_status "    \033[32m✓ OTel scaler memstore data collected\033[0m"
        else
            dump::__print_status "    \033[31m✗ Failed to collect OTel scaler memstore data\033[0m"
        fi
        
        # Cleanup OTel port forwards
        for pid in "${otel_pids[@]}"; do
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
        set -m 2>/dev/null || true  # Re-enable job control
        
        dump::__print_status "  \033[32m✓ Kedify OTel Add-on service data collected\033[0m"
        otel_helm_found=true
    fi
    
    if [[ "$otel_helm_found" == "false" ]]; then
        dump::__print_status "  \033[90m- No Kedify OTel Add-on found in this namespace\033[0m"
    fi
    
    # If this is the installation namespace, collect all pods and their logs
    if [[ "$is_installation_ns" == "true" ]]; then
        dump::__print_status "\033[36mCollecting installation data...\033[0m"
        
        # Get all pods in the installation namespace
        local all_pods
        IFS=$'\n' read -d '' -r -a all_pods < <(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' && printf '\0')
        
        # Collect pod manifests, descriptions, and logs
        if [[ ${#all_pods[@]} -gt 0 ]]; then
            for pod in "${all_pods[@]}"; do
                dump::__print_status "  \033[36m- Processing pod:\033[0m $pod"
                kubectl get pod -n "$ns" "$pod" -o yaml > "${ns_dir}/${pod}-pod.yaml" 2>/dev/null || dump::__print_status "    \033[31mFailed to get pod YAML for $pod\033[0m"
                kubectl describe pod -n "$ns" "$pod" > "${ns_dir}/${pod}-pod.describe.txt" 2>/dev/null || dump::__print_status "    \033[31mFailed to describe pod $pod\033[0m"
                kubectl logs -n "$ns" "$pod" > "${ns_dir}/${pod}-logs.txt" 2>/dev/null || dump::__print_status "    \033[31mFailed to get logs for $pod\033[0m"
                
                # Try to get previous logs if pod has restarted
                kubectl logs -n "$ns" "$pod" --previous > "${ns_dir}/${pod}-logs-previous.txt" 2>/dev/null || true
            done
            dump::__print_status "  \033[32m✓ Pod data collected\033[0m"
        else
            dump::__print_status "  \033[90m- No pods found in installation namespace\033[0m"
        fi
        
        # Collect resource usage for all pods in the installation namespace
        dump::__print_status "  \033[36m- Collecting resource usage for all pods...\033[0m"
        if kubectl top pod -n "$ns" --no-headers 2>/dev/null > "${ns_dir}/pods-resource-usage.txt"; then
            dump::__print_status "    \033[32m✓ Resource usage collected\033[0m"
        else
            dump::__print_status "    \033[31m✗ Failed to get resource usage (metrics-server may not be available)\033[0m"
        fi
        
        # Collect Kedify resource
        dump::__print_status "  \033[36m- Collecting Kedify resource...\033[0m"
        if kubectl get crd kedifyconfigurations.install.kedify.io >/dev/null 2>&1; then
            if kubectl get kedifyconfigurations -n "$ns" --no-headers 2>/dev/null | grep -q .; then
                kubectl get kedifyconfigurations -n "$ns" -o yaml > "${ns_dir}/kedify-resource.yaml" 2>/dev/null
                dump::__print_status "    \033[32m✓ Kedify resource collected\033[0m"
            else
                dump::__print_status "    \033[90m- No Kedify resource found in this namespace\033[0m"
            fi
        else
            dump::__print_status "    \033[90m- Kedify CRD not available (Kedify not installed)\033[0m"
        fi
        
        # Collect Helm installation information if available
        dump::__print_status "\033[36mCollecting Helm installation information...\033[0m"
        local helm_secrets_found=false
        
        # Check for kedify-agent Helm release secret
        if kubectl get secret -n "$ns" sh.helm.release.v1.kedify-agent.v1 >/dev/null 2>&1; then
            if dump::__extract_helm_release_data "$ns" "sh.helm.release.v1.kedify-agent.v1" "$ns_dir" "helm-kedify-agent-"; then
                helm_secrets_found=true
            fi
        fi
        
        # Check for other common Helm release secrets (keda, keda-add-ons-http, kedify, etc.)
        # Note: OTel patterns (kedify-otel, keda-otel-scaler) are excluded to prevent duplication with per-namespace collection
        local helm_release_patterns=("sh.helm.release.v1.keda.v*" "sh.helm.release.v1.keda-add-ons-http.v*" "sh.helm.release.v1.kedify.v*")
        for pattern in "${helm_release_patterns[@]}"; do
            while IFS= read -r secret_name; do
                if [[ -n "$secret_name" && "$secret_name" != "sh.helm.release.v1.kedify-agent.v1" ]]; then
                    if dump::__extract_helm_release_data "$ns" "$secret_name" "$ns_dir" "helm-"; then
                        helm_secrets_found=true
                    fi
                fi
            done < <(kubectl get secrets -n "$ns" -o name 2>/dev/null | grep -E "^secret/${pattern//\*/.*}$" | sed 's|^secret/||' || true)
        done
        
        if [[ "$helm_secrets_found" == "false" ]]; then
            dump::__print_status "    \033[90m- No Helm release secrets found (not installed via Helm)\033[0m"
        fi
        
        # Collect HTTP Add-on queue information if HTTP Add-on pods exist
        if kubectl get pods -l app.kubernetes.io/name=http-add-on -l app.kubernetes.io/component=interceptor -n "$ns" > /dev/null 2>&1; then
            dump::__print_status "  \033[36m- Collecting HTTP Add-on queue data...\033[0m"
            
            # Individual queue data (per pod) - formatted as table
            dump::__collect_http_addon_queue_data "$ns" "$ns_dir" "" "individual" "http-addon-queue-individual.txt" "Failed to collect individual queue data"
            
            # Aggregated queue data - formatted as table
            dump::__collect_http_addon_queue_data "$ns" "$ns_dir" "" "aggregated" "http-addon-queue-aggregated.txt" "Failed to collect aggregated queue data"
            
            # JSON format for programmatic access - individual mode
            dump::__collect_http_addon_queue_data "$ns" "$ns_dir" "json" "individual" "http-addon-queue.json" "Failed to collect JSON queue data"
            
            dump::__print_status "    \033[32m✓ HTTP Add-on queue data collected\033[0m"
        fi
    fi
    
    # Clear the trap as we're ending the function normally
    trap - INT TERM EXIT
    
    dump::__print_status "\033[32mCompleted: $ns\033[0m"
    dump::__print_status ""
}

function dump::cmd() {
    # Check if required tools are available
    local missing_tools=()
    
    # Essential tools
    if ! command -v curl >/dev/null 2>&1; then
        missing_tools+=("curl")
    fi
    
    if ! command -v jq >/dev/null 2>&1; then
        missing_tools+=("jq")
    fi
    
    if ! command -v kubectl >/dev/null 2>&1; then
        missing_tools+=("kubectl")
    fi
    
    if ! command -v column >/dev/null 2>&1; then
        missing_tools+=("column")
    fi
    
    if ! command -v yq >/dev/null 2>&1; then
        missing_tools+=("yq")
    fi
    
    if ! command -v gunzip >/dev/null 2>&1; then
        missing_tools+=("gunzip")
    fi
    
    if ! command -v base64 >/dev/null 2>&1; then
        missing_tools+=("base64")
    fi
    
    # Report missing tools
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "Error: The following required tools are missing:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "Installation instructions:"
        echo "  macOS (using Homebrew):"
        echo "    brew install curl jq kubectl yq coreutils"
        echo ""
        echo "  Ubuntu/Debian:"
        echo "    sudo apt-get install curl jq kubectl util-linux gzip tar coreutils"
        echo "    # For yq: sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
        echo ""
        echo "  CentOS/RHEL:"
        echo "    sudo yum install curl jq util-linux gzip tar coreutils"
        echo "    # Install kubectl: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
        echo "    # For yq: sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && sudo chmod +x /usr/local/bin/yq"
        echo ""
        echo "  Alpine:"
        echo "    apk add curl jq kubectl yq util-linux gzip tar coreutils"
        echo ""
        echo "  Windows (using Chocolatey):"
        echo "    choco install curl jq kubernetes-cli yq"
        echo "  Windows (using Scoop):"
        echo "    scoop install curl jq kubectl yq"
        echo "  Windows (using winget):"
        echo "    winget install --id=cURL.cURL --id=jqlang.jq --id=Kubernetes.kubectl --id=MikeFarah.yq"
        echo ""
        exit 1
    fi
    
    local target_ns=""
    local output_dir="."
    local create_archive="false"
    local all_namespaces="false"
    local quiet_mode="false"
    local next="false"
    local next_type=""
    
    # Get current namespace as default
    local current_ns
    current_ns=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "default")
    if [[ -z "$current_ns" ]]; then
        current_ns="default"
    fi
    
    for o in "$@"; do
        if [[ "$next" == "true" ]]; then
            case "$next_type" in
                "output")
                    output_dir="$o"
                    ;;
                "namespace")
                    target_ns="$o"
                    ;;
                "collect-cluster-data")
                    COLLECT_CLUSTER_DATA="$(dump::__validate_bool "$o")"
                    ;;
            esac
            next="false"
            next_type=""
            continue
        fi
        case $o in
            -o|--output)
                next="true"
                next_type="output"
                ;;
            -o=*|--output=*)
                output_dir="${o#*=}"
                ;;
            -o*)
                output_dir="${o#-o}"
                ;;
            --output*)
                output_dir="${o#--output}"
                ;;
            -n|--namespace)
                next="true"
                next_type="namespace"
                ;;
            -n=*|--namespace=*)
                target_ns="${o#*=}"
                ;;
            -n*)
                target_ns="${o#-n}"
                ;;
            --namespace*)
                target_ns="${o#--namespace}"
                ;;
            -A|--all-namespaces)
                all_namespaces="true"
                ;;
            -q|--quiet)
                quiet_mode="true"
                QUIET_MODE="true"
                ;;
            -a|--archive)
                create_archive="true"
                ;;
            -c|--collect-cluster-data)
                next="true"
                next_type="collect-cluster-data"
                ;;
            -c=*|--collect-cluster-data=*)
                COLLECT_CLUSTER_DATA="$(dump::__validate_bool "${o#*=}")"
                ;;
            -c*)
                if [[ "$o" == "-c="* ]]; then
                    COLLECT_CLUSTER_DATA="$(dump::__validate_bool "${o#-c=}")"
                else
                    COLLECT_CLUSTER_DATA="$(dump::__validate_bool "${o#-c}")"
                fi
                ;;
            --collect-cluster-data*)
                if [[ "$o" == "--collect-cluster-data="* ]]; then
                    COLLECT_CLUSTER_DATA="$(dump::__validate_bool "${o#--collect-cluster-data=}")"
                else
                    COLLECT_CLUSTER_DATA="$(dump::__validate_bool "${o#--collect-cluster-data}")"
                fi
                ;;
            -h|--help)
                dump::__print_usage
                exit 0
                ;;
            *)
                echo "Unknown flag: $o"
                echo "" 
                echo "Available flags:"
                echo "  -o|--output         ... output directory or archive file path (default: current directory)"
                echo "  -n|--namespace      ... specific namespace (default: current namespace)"
                echo "  -A|--all-namespaces ... collect from all namespaces"
                echo "  -q|--quiet          ... quiet mode - suppress all status output"
                echo "  -a|--archive        ... create tar.gz archive"
                echo "  -c|--collect-cluster-data=BOOL ... collect cluster-wide data (default: true)"
                echo "  -h|--help           ... show this help message"
                dump::__print_usage
                exit 1
                ;;
        esac
    done
    
    # Set up output directory
    local tempdir
    if [[ "$create_archive" == "true" || "$output_dir" == *.tar.gz ]]; then
        # Check if tar is available when archive functionality is requested
        if ! command -v tar >/dev/null 2>&1; then
            echo "Error: tar is required for creating archives but not installed."
            echo "Please install tar before using the --archive option."
            echo ""
            echo "Installation instructions:"
            echo "  macOS: tar is pre-installed"
            echo "  Ubuntu/Debian: tar is pre-installed"
            echo "  CentOS/RHEL: tar is pre-installed"
            echo "  Alpine: tar is pre-installed"
            echo "  Windows: tar is included in Windows 10+ (build 17063+)"
            echo ""
            exit 1
        fi
        tempdir=$(mktemp -d)
        create_archive="true"
    else
        tempdir="$output_dir/kedify-dump-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$tempdir"
    fi
    
    dump::__print_status ""
    if command -v figlet >/dev/null 2>&1; then
        dump::__print_status "$(figlet dump)"
    else
        dump::__print_status "DUMP"
    fi
    dump::__print_status ""
    dump::__print_status "\033[36mOutput directory:\033[0m $tempdir"
    dump::__print_status "\033[36mKubectl context:\033[0m $(kubectl config current-context)"
    
    # Determine installation namespace (where Kedify/KEDA is installed)
    local installation_ns=""
    if kubectl get crd kedifyconfigurations.install.kedify.io >/dev/null 2>&1 && kubectl get kedifyconfigurations -A > /dev/null 2>&1; then
        installation_ns=$(kubectl get kedifyconfigurations -A -o json | jq -r '.items[0].metadata.namespace')
        dump::__print_status "\033[36mDetected Kedify installation in namespace:\033[0m $installation_ns"
    elif kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
        # Try to find KEDA operator deployment
        local keda_ns=$(kubectl get deployments --all-namespaces -l app.kubernetes.io/name=keda-operator -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || echo "")
        if [[ -n "$keda_ns" ]]; then
            installation_ns="$keda_ns"
            dump::__print_status "\033[36mDetected KEDA installation in namespace:\033[0m $installation_ns"
        else
            installation_ns="keda"
            dump::__print_status "\033[36mKEDA CRDs found, assuming namespace:\033[0m $installation_ns"
        fi
    else
        # Default to keda namespace if we can't detect anything
        installation_ns="keda"
        dump::__print_status "\033[36mNo Kedify/KEDA detected, assuming namespace:\033[0m $installation_ns"
    fi
    
    # Collect namespaces to process
    local namespaces=()
    if [[ "$all_namespaces" == "true" ]]; then
        IFS=$'\n' read -d '' -r -a namespaces < <(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' && printf '\0')
        dump::__print_status "\033[36mScope:\033[0m All namespaces (${#namespaces[@]} total)"
    else
        if [[ -n "$target_ns" ]]; then
            namespaces=("$target_ns")
        else
            namespaces=("$current_ns")
        fi
        dump::__print_status "\033[36mScope:\033[0m Namespace - ${namespaces[*]}"
    fi
    dump::__print_status ""
    
    # Collect cluster-wide information if enabled
    if [[ "$COLLECT_CLUSTER_DATA" == "true" ]]; then
        dump::__print_status "\033[33m=== Processing Cluster Information ===\033[0m"
        
        # Create cluster information directory
        local cluster_dir="${tempdir}/_cluster-info"
        mkdir -p "$cluster_dir"
        
        # Node Information Section
        dump::__print_status "\033[36mCollecting node information...\033[0m"
    
    # Node resource usage
    if kubectl top nodes --no-headers 2>/dev/null > "${cluster_dir}/cluster-nodes-resource-usage.txt"; then
        dump::__print_status "  \033[32m✓ Node resource usage collected\033[0m"
    else
        dump::__print_status "  \033[31m✗ Failed to get node resource usage (metrics-server may not be available)\033[0m"
    fi
    
    # Node details and conditions
    if kubectl get nodes -o yaml > "${cluster_dir}/cluster-nodes.yaml" 2>/dev/null; then
        dump::__print_status "  \033[32m✓ Node details collected\033[0m"
    else
        dump::__print_status "  \033[31m✗ Failed to collect node details\033[0m"
    fi
    
    # Node descriptions (includes conditions, taints, allocatable resources)
    kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | while read -r node; do
        kubectl describe node "$node" > "${cluster_dir}/cluster-node-${node}-describe.txt" 2>/dev/null || true
    done
    dump::__print_status "  \033[32m✓ Node descriptions collected\033[0m"
    
    # Pod resource requests vs node capacity
    local resource_allocation_temp="${cluster_dir}/cluster-resource-allocation-temp.txt"
    if kubectl describe nodes 2>/dev/null | grep -A 15 "Allocated resources:" > "$resource_allocation_temp" 2>/dev/null && [[ -s "$resource_allocation_temp" ]]; then
        mv "$resource_allocation_temp" "${cluster_dir}/cluster-resource-allocation.txt"
        dump::__print_status "  \033[32m✓ Resource allocation summary collected\033[0m"
    else
        rm -f "$resource_allocation_temp"
        dump::__print_status "  \033[31m✗ Failed to collect resource allocation summary\033[0m"
    fi
    
    # Cluster Infrastructure Section
    dump::__print_status "\033[36mCollecting cluster infrastructure data...\033[0m"
    
    # Cluster autoscaler detection and comprehensive data collection
    local autoscaler_detected="false"
    
    # Check for cluster autoscaler in multiple ways
    if kubectl get deployments --all-namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q "cluster-autoscaler" || \
       kubectl get pods --all-namespaces -l app=cluster-autoscaler --no-headers 2>/dev/null | grep -q . || \
       kubectl get configmaps --all-namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | grep -q "cluster-autoscaler"; then
        autoscaler_detected="true"
    fi
    
    if [[ "$autoscaler_detected" == "true" ]]; then
        dump::__print_status "  \033[36m- Collecting Cluster Autoscaler data...\033[0m"
        
        # Cluster autoscaler events
        local autoscaler_events_temp="${cluster_dir}/cluster-autoscaler-events-temp.yaml"
        if kubectl get events --all-namespaces --field-selector reason=ScaledUpGroup,reason=ScaledDownGroup,reason=FailedToScaleUpGroup,reason=FailedToScaleDownGroup --sort-by='.lastTimestamp' -o yaml > "$autoscaler_events_temp" 2>/dev/null && [[ -s "$autoscaler_events_temp" ]]; then
            # Check if the file has actual events (not just empty YAML structure)
            if grep -q "^- " "$autoscaler_events_temp" 2>/dev/null; then
                mv "$autoscaler_events_temp" "${cluster_dir}/cluster-autoscaler-events.yaml"
                dump::__print_status "    \033[32m✓ Cluster autoscaler events collected\033[0m"
            else
                rm -f "$autoscaler_events_temp"
                dump::__print_status "    \033[90m- No cluster autoscaler events found\033[0m"
            fi
        else
            rm -f "$autoscaler_events_temp"
            # Fallback: collect all events and filter for autoscaler-related ones
            if kubectl get events --all-namespaces --sort-by='.lastTimestamp' -o yaml 2>/dev/null | grep -A 10 -B 5 -i "autoscaler\|scaled.*group\|node.*pressure\|insufficient.*resources" > "${cluster_dir}/cluster-autoscaler-events.yaml" 2>/dev/null && [[ -s "${cluster_dir}/cluster-autoscaler-events.yaml" ]]; then
                dump::__print_status "    \033[32m✓ Cluster autoscaler events collected (filtered)\033[0m"
            else
                rm -f "${cluster_dir}/cluster-autoscaler-events.yaml"
                dump::__print_status "    \033[90m- No cluster autoscaler events found\033[0m"
            fi
        fi
        
        # Cluster autoscaler deployment(s)
        kubectl get deployments --all-namespaces -l app=cluster-autoscaler -o yaml > "${cluster_dir}/cluster-autoscaler-deployments.yaml" 2>/dev/null || \
        kubectl get deployments --all-namespaces --field-selector metadata.name=cluster-autoscaler -o yaml > "${cluster_dir}/cluster-autoscaler-deployments.yaml" 2>/dev/null
        if [[ -s "${cluster_dir}/cluster-autoscaler-deployments.yaml" ]]; then
            dump::__print_status "    \033[32m✓ Cluster autoscaler deployments collected\033[0m"
        else
            rm -f "${cluster_dir}/cluster-autoscaler-deployments.yaml"
            dump::__print_status "    \033[90m- No cluster autoscaler deployments found\033[0m"
        fi
        
        # Cluster autoscaler pods and their status
        kubectl get pods --all-namespaces -l app=cluster-autoscaler -o yaml > "${cluster_dir}/cluster-autoscaler-pods.yaml" 2>/dev/null
        if [[ -s "${cluster_dir}/cluster-autoscaler-pods.yaml" ]]; then
            dump::__print_status "    \033[32m✓ Cluster autoscaler pods collected\033[0m"
        else
            rm -f "${cluster_dir}/cluster-autoscaler-pods.yaml"
            # Fallback: search by name pattern
            kubectl get pods --all-namespaces --field-selector metadata.name~=cluster-autoscaler -o yaml > "${cluster_dir}/cluster-autoscaler-pods.yaml" 2>/dev/null || true
            if [[ -s "${cluster_dir}/cluster-autoscaler-pods.yaml" ]]; then
                dump::__print_status "    \033[32m✓ Cluster autoscaler pods collected (by name)\033[0m"
            else
                rm -f "${cluster_dir}/cluster-autoscaler-pods.yaml"
                dump::__print_status "    \033[90m- No cluster autoscaler pods found\033[0m"
            fi
        fi
        
        # Cluster autoscaler configuration (ConfigMaps)
        kubectl get configmaps --all-namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -i "cluster-autoscaler\|autoscaling" | while read -r cm_name; do
            if [[ -n "$cm_name" ]]; then
                local cm_namespace=$(kubectl get configmap "$cm_name" --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
                kubectl get configmap "$cm_name" -n "$cm_namespace" -o yaml > "${cluster_dir}/cluster-autoscaler-config-${cm_name}.yaml" 2>/dev/null || true
            fi
        done
        if ls "${cluster_dir}"/cluster-autoscaler-config-*.yaml >/dev/null 2>&1; then
            dump::__print_status "    \033[32m✓ Cluster autoscaler configuration collected\033[0m"
        else
            dump::__print_status "    \033[90m- No cluster autoscaler configuration found\033[0m"
        fi
        
        # Cluster autoscaler controller logs
        kubectl get pods --all-namespaces -l app=cluster-autoscaler -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | while read -r pod; do
            if [[ -n "$pod" ]]; then
                local pod_namespace=$(kubectl get pod "$pod" --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
                kubectl logs -n "$pod_namespace" "$pod" --tail=1000 > "${cluster_dir}/cluster-autoscaler-${pod}-logs.txt" 2>/dev/null || true
                kubectl logs -n "$pod_namespace" "$pod" --previous --tail=1000 > "${cluster_dir}/cluster-autoscaler-${pod}-logs-previous.txt" 2>/dev/null || true
            fi
        done
        if ls "${cluster_dir}"/cluster-autoscaler-*-logs.txt >/dev/null 2>&1; then
            dump::__print_status "    \033[32m✓ Cluster autoscaler controller logs collected\033[0m"
        else
            dump::__print_status "    \033[90m- No cluster autoscaler controller logs found\033[0m"
        fi
        
        # Cluster autoscaler status (from status API if available)
        kubectl get pods --all-namespaces -l app=cluster-autoscaler -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | while read -r pod; do
            if [[ -n "$pod" ]]; then
                local pod_namespace=$(kubectl get pod "$pod" --all-namespaces -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
                # Try to get autoscaler status via API (port 8085 is common for cluster autoscaler)
                kubectl get pod -n "$pod_namespace" "$pod" -o jsonpath='{.spec.containers[*].ports[*].containerPort}' 2>/dev/null | tr ' ' '\n' | while read -r port; do
                    if [[ "$port" == "8085" ]] || [[ "$port" == "8086" ]]; then
                        kubectl port-forward -n "$pod_namespace" "$pod" "8085:$port" >/dev/null 2>&1 &
                        local pf_pid=$!
                        sleep 2
                        curl -s --max-time 5 "http://localhost:8085/api/v1/status" > "${cluster_dir}/cluster-autoscaler-${pod}-status.json" 2>/dev/null || true
                        curl -s --max-time 5 "http://localhost:8085/metrics" > "${cluster_dir}/cluster-autoscaler-${pod}-metrics.txt" 2>/dev/null || true
                        kill $pf_pid 2>/dev/null || true
                        wait $pf_pid 2>/dev/null || true
                        break
                    fi
                done
            fi
        done
        if ls "${cluster_dir}"/cluster-autoscaler-*-status.json >/dev/null 2>&1; then
            dump::__print_status "    \033[32m✓ Cluster autoscaler status collected\033[0m"
        else
            dump::__print_status "    \033[90m- No cluster autoscaler status API available\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- Cluster autoscaler not detected\033[0m"
        
        # Still collect general autoscaler events even if deployment not found
        local autoscaler_events_temp="${cluster_dir}/cluster-autoscaler-events-temp.yaml"
        if kubectl get events --all-namespaces --field-selector reason=ScaledUpGroup,reason=ScaledDownGroup,reason=FailedToScaleUpGroup,reason=FailedToScaleDownGroup --sort-by='.lastTimestamp' -o yaml > "$autoscaler_events_temp" 2>/dev/null && [[ -s "$autoscaler_events_temp" ]]; then
            # Check if the file has actual events (not just empty YAML structure)
            if grep -q "^- " "$autoscaler_events_temp" 2>/dev/null; then
                mv "$autoscaler_events_temp" "${cluster_dir}/cluster-autoscaler-events.yaml"
                dump::__print_status "  \033[32m✓ Cluster autoscaler events collected\033[0m"
            else
                rm -f "$autoscaler_events_temp"
            fi
        else
            rm -f "$autoscaler_events_temp"
        fi
    fi
    
    # Karpenter events and resources (if Karpenter is installed)
    local karpenter_detected="false"
    
    # Check for Karpenter in multiple ways
    if kubectl get nodes -o jsonpath='{.items[*].metadata.labels}' 2>/dev/null | grep -q "karpenter\|provisioner" || \
       kubectl get pods -n karpenter --no-headers 2>/dev/null | grep -q karpenter || \
       kubectl get crd | grep -q "karpenter.sh" 2>/dev/null; then
        karpenter_detected="true"
    fi
    
    if [[ "$karpenter_detected" == "true" ]]; then
        dump::__print_status "  \033[36m- Collecting Karpenter data...\033[0m"
        
        # Karpenter events
        local karpenter_events_temp="${cluster_dir}/karpenter-events-temp.yaml"
        if kubectl get events --all-namespaces --sort-by='.lastTimestamp' -o yaml 2>/dev/null | grep -A 10 -B 5 -i "karpenter\|provisioner\|nodepool\|nodeclaim" > "$karpenter_events_temp" 2>/dev/null && [[ -s "$karpenter_events_temp" ]]; then
            mv "$karpenter_events_temp" "${cluster_dir}/karpenter-events.yaml"
            dump::__print_status "    \033[32m✓ Karpenter events collected\033[0m"
        else
            rm -f "$karpenter_events_temp"
            dump::__print_status "    \033[90m- No Karpenter events found\033[0m"
        fi
        
        # Karpenter NodePools (v1beta1)
        if kubectl get nodepools.karpenter.sh -o yaml > "${cluster_dir}/karpenter-nodepools.yaml" 2>/dev/null && [[ -s "${cluster_dir}/karpenter-nodepools.yaml" ]]; then
            dump::__print_status "    \033[32m✓ Karpenter NodePools collected\033[0m"
        else
            rm -f "${cluster_dir}/karpenter-nodepools.yaml"
            dump::__print_status "    \033[90m- No Karpenter NodePools found\033[0m"
        fi
        
        # Karpenter NodeClaims (v1beta1)
        if kubectl get nodeclaims.karpenter.sh -o yaml > "${cluster_dir}/karpenter-nodeclaims.yaml" 2>/dev/null && [[ -s "${cluster_dir}/karpenter-nodeclaims.yaml" ]]; then
            dump::__print_status "    \033[32m✓ Karpenter NodeClaims collected\033[0m"
        else
            rm -f "${cluster_dir}/karpenter-nodeclaims.yaml"
            dump::__print_status "    \033[90m- No Karpenter NodeClaims found\033[0m"
        fi
        
        # Legacy Karpenter Provisioners (v1alpha5 - for backward compatibility)
        if kubectl get provisioners.karpenter.sh -o yaml > "${cluster_dir}/karpenter-provisioners.yaml" 2>/dev/null && [[ -s "${cluster_dir}/karpenter-provisioners.yaml" ]]; then
            dump::__print_status "    \033[32m✓ Karpenter Provisioners (legacy) collected\033[0m"
        else
            rm -f "${cluster_dir}/karpenter-provisioners.yaml"
        fi
        
        # Karpenter controller logs (if running in karpenter namespace)
        if kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter --no-headers 2>/dev/null | grep -q .; then
            kubectl get pods -n karpenter -l app.kubernetes.io/name=karpenter -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | while read -r pod; do
                if [[ -n "$pod" ]]; then
                    kubectl logs -n karpenter "$pod" --tail=1000 > "${cluster_dir}/karpenter-${pod}-logs.txt" 2>/dev/null || true
                    kubectl logs -n karpenter "$pod" --previous --tail=1000 > "${cluster_dir}/karpenter-${pod}-logs-previous.txt" 2>/dev/null || true
                fi
            done
            dump::__print_status "    \033[32m✓ Karpenter controller logs collected\033[0m"
        fi
    else
        dump::__print_status "  \033[90m- Karpenter not detected\033[0m"
    fi
    
    # Pending pods (may indicate resource constraints)
    local pending_count=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [[ $pending_count -gt 0 ]]; then
        kubectl get pods --all-namespaces --field-selector=status.phase=Pending -o yaml > "${cluster_dir}/cluster-pending-pods.yaml" 2>/dev/null
        dump::__print_status "  \033[33m⚠ Found $pending_count pending pod(s) - may indicate resource constraints\033[0m"
    else
        dump::__print_status "  \033[32m✓ No pending pods found\033[0m"
    fi
    
    dump::__print_status "\033[32mCompleted: cluster information\033[0m"
    else
        dump::__print_status "\033[90mSkipping cluster-wide data collection (--collect-cluster-data=false)\033[0m"
    fi
    
    dump::__print_status ""
    
    # Always include installation namespace if not already included
    local include_installation="true"
    for ns in "${namespaces[@]}"; do
        if [[ "$ns" == "$installation_ns" ]]; then
            include_installation="false"
            break
        fi
    done
    
    # Process each namespace
    local collected_namespaces=()
    for ns in "${namespaces[@]}"; do
        local is_installation="false"
        if [[ "$ns" == "$installation_ns" ]]; then
            is_installation="true"
        fi
        
        # For non-installation namespaces, check if they have relevant resources
        if [[ "$is_installation" == "false" ]]; then
            local has_proxy=$(kubectl get pods -n "$ns" -l app=kedify-proxy --no-headers 2>/dev/null | wc -l || echo "0")
            local has_so=0
            local has_hpa=0
            local has_sj=0
            local has_hso=0
            
            # Check for ScaledObjects (only if CRD exists)
            if kubectl get crd scaledobjects.keda.sh >/dev/null 2>&1; then
                has_so=$(kubectl get scaledobjects -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            fi
            
            # Check for HPAs
            has_hpa=$(kubectl get hpa -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            
            # Check for ScaledJobs (only if CRD exists)
            if kubectl get crd scaledjobs.keda.sh >/dev/null 2>&1; then
                has_sj=$(kubectl get scaledjobs -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            fi
            
            # Check for HTTPScaledObjects (only if CRD exists)
            if kubectl get crd httpscaledobjects.http.keda.sh >/dev/null 2>&1; then
                has_hso=$(kubectl get httpscaledobjects -n "$ns" --no-headers 2>/dev/null | wc -l || echo "0")
            fi
            
            # Skip if no relevant resources
            if [[ "$has_proxy" -eq 0 && "$has_so" -eq 0 && "$has_hpa" -eq 0 && "$has_sj" -eq 0 && "$has_hso" -eq 0 ]]; then
                continue
            fi
        fi
        
        dump::__collect_namespace_data "$ns" "$tempdir" "$is_installation"
        collected_namespaces+=("$ns")
    done
    
    # Process installation namespace separately if not already included
    if [[ "$include_installation" == "true" ]]; then
        dump::__collect_namespace_data "$installation_ns" "$tempdir" "true"
        # Add to collected namespaces if not already there
        local found=false
        if [[ ${#collected_namespaces[@]} -gt 0 ]]; then
            for ns in "${collected_namespaces[@]}"; do
                if [[ "$ns" == "$installation_ns" ]]; then
                    found=true
                    break
                fi
            done
        fi
        if [[ "$found" == "false" ]]; then
            collected_namespaces+=("$installation_ns")
        fi
    fi
    
    # Generate cluster health summary
    dump::__print_status "\033[36mGenerating cluster health summary...\033[0m"
    dump::__generate_cluster_health_summary "$tempdir" "$cluster_dir"
    dump::__print_status "  \033[32m✓ Cluster health summary generated\033[0m"
    
    # Create summary file
    cat > "${tempdir}/dump-summary.txt" << EOF
Kedify Diagnostic Information
=============================
Generated: $(date)
Kubectl Context: $(kubectl config current-context)
Installation Namespace: $installation_ns
Namespaces Processed: ${#collected_namespaces[@]:-0}

Top-level Files:
- dump-summary.txt                        ... This summary file
- cluster-health-summary.txt              ... Quick overview of cluster health and issues

Cluster-wide Files (_cluster-info/):
- cluster-nodes-resource-usage.txt        ... CPU/Memory usage for all nodes
- cluster-nodes.yaml                      ... Complete node specifications and status
- cluster-node-*-describe.txt             ... Detailed node descriptions (conditions, taints, allocations)$(if [[ -f "${cluster_dir}/cluster-resource-allocation.txt" ]]; then echo "
- cluster-resource-allocation.txt         ... Resource allocation summary across nodes"; fi)$(if [[ -f "${cluster_dir}/cluster-autoscaler-events.yaml" ]]; then echo "
- cluster-autoscaler-events.yaml          ... Cluster autoscaler scaling events"; fi)$(if [[ -f "${cluster_dir}/cluster-autoscaler-deployments.yaml" ]]; then echo "
- cluster-autoscaler-deployments.yaml     ... Cluster autoscaler deployment configurations"; fi)$(if [[ -f "${cluster_dir}/cluster-autoscaler-pods.yaml" ]]; then echo "
- cluster-autoscaler-pods.yaml            ... Cluster autoscaler pod specifications"; fi)$(if ls "${cluster_dir}"/cluster-autoscaler-config-*.yaml >/dev/null 2>&1; then echo "
- cluster-autoscaler-config-*.yaml        ... Cluster autoscaler configuration files"; fi)$(if ls "${cluster_dir}"/cluster-autoscaler-*-logs.txt >/dev/null 2>&1; then echo "
- cluster-autoscaler-*-logs.txt           ... Cluster autoscaler controller logs"; fi)$(if ls "${cluster_dir}"/cluster-autoscaler-*-status.json >/dev/null 2>&1; then echo "
- cluster-autoscaler-*-status.json        ... Cluster autoscaler status API output"; fi)$(if [[ -f "${cluster_dir}/karpenter-events.yaml" ]]; then echo "
- karpenter-events.yaml                   ... Karpenter scaling events"; fi)$(if [[ -f "${cluster_dir}/karpenter-nodepools.yaml" ]]; then echo "
- karpenter-nodepools.yaml                ... Karpenter NodePool configurations"; fi)$(if [[ -f "${cluster_dir}/karpenter-nodeclaims.yaml" ]]; then echo "
- karpenter-nodeclaims.yaml               ... Karpenter NodeClaim status"; fi)$(if [[ -f "${cluster_dir}/karpenter-provisioners.yaml" ]]; then echo "
- karpenter-provisioners.yaml             ... Karpenter Provisioners (legacy)"; fi)$(if ls "${cluster_dir}"/karpenter-*-logs.txt >/dev/null 2>&1; then echo "
- karpenter-*-logs.txt                    ... Karpenter controller logs"; fi)$(if [[ -f "${cluster_dir}/cluster-pending-pods.yaml" ]]; then echo "
- cluster-pending-pods.yaml               ... Pods stuck in Pending state (resource constraints)"; fi)

Per-namespace Files:
- events.yaml                             ... Kubernetes events for the namespace
- scaledobjects.yaml                      ... ScaledObject resources (if any)
- hpa.yaml                                ... HorizontalPodAutoscaler resources (if any)
- scaledjobs.yaml                         ... ScaledJob resources (if any)
- httpscaledobjects.yaml                  ... HTTPScaledObject resources (if any)
- httpscaledobjects-services.yaml         ... Services referenced by HTTPScaledObjects (if any)
- podresourceprofiles.yaml                ... PodResourceProfile resources (if any)
- scalinggroups.yaml                      ... ScalingGroup resources (if any)
- scalingpolicies.yaml                    ... ScalingPolicy resources (if any)
- kedify-proxy-*-pod.yaml                 ... Pod manifests for kedify-proxy pods
- kedify-proxy-*-logs.txt                 ... Logs from kedify-proxy pods
- kedify-proxy-*-config_dump.json         ... Envoy configuration dumps
- kedify-proxy-*-prometheus.txt           ... Prometheus metrics from kedify-proxy

Installation namespace additional files:
- kedify-resource.yaml                    ... KedifyConfiguration resource (if any)
- helm-kedify-agent-values.yaml           ... Kedify Helm values used during installation (if available)
- helm-kedify-agent-info.txt              ... Kedify Helm version information (if available)
- helm-*-values.yaml                      ... Additional Helm values files (KEDA, HTTP Add-on, etc.)
- http-addon-queue-*.txt                  ... HTTP Add-on queue data in table format
- http-addon-queue.json                   ... HTTP Add-on queue data in JSON format

Directory Structure:
$(find "$tempdir" -type d | sort)

Files collected:
$(find "$tempdir" -type f -name "*.yaml" -o -name "*.txt" -o -name "*.json" | sort)
EOF
    
    if [[ "$create_archive" == "true" ]]; then
        local archive_file
        if [[ "$output_dir" == *.tar.gz ]]; then
            archive_file="$output_dir"
        else
            if [[ "$output_dir" == "." ]]; then
                archive_file="kedify-dump-$(date +%Y%m%d-%H%M%S).tar.gz"
            else
                archive_file="${output_dir}/kedify-dump-$(date +%Y%m%d-%H%M%S).tar.gz"
            fi
        fi
        
        # Convert to absolute path if it's relative
        if [[ "${archive_file:0:1}" != "/" ]]; then
            archive_file="$(pwd)/${archive_file}"
        fi
        
        dump::__print_status "\033[36mCreating tar.gz archive:\033[0m $archive_file"
        (cd "$tempdir" && tar -czf "$archive_file" . >/dev/null 2>&1)
        rm -rf "$tempdir"
        dump::__print_status ""
        dump::__print_status "\033[32mDiagnostic information saved to:\033[0m $archive_file"
    else
        dump::__print_status ""
        dump::__print_status "\033[32m=== Collection Complete! ===\033[0m"
        dump::__print_status ""
        dump::__print_status "\033[32mDiagnostic information saved to:\033[0m $tempdir"
        dump::__print_status ""
        dump::__print_status "\033[36mQuick commands to explore:\033[0m"
        dump::__print_status "   ls -la $tempdir"
        dump::__print_status "   cat $tempdir/dump-summary.txt"
    fi
}

function dump::__generate_cluster_health_summary() {
    local tempdir="$1"
    local cluster_dir="$2"
    local summary_file="${tempdir}/cluster-health-summary.txt"
    
    echo "Cluster Health Summary" > "$summary_file"
    echo "=====================" >> "$summary_file"
    echo "Generated: $(date)" >> "$summary_file"
    echo "" >> "$summary_file"
    
    # Node status
    echo "Node Status:" >> "$summary_file"
    kubectl get nodes --no-headers 2>/dev/null | while read -r line; do
        echo "  $line" >> "$summary_file"
    done 2>/dev/null || echo "  Failed to get node status" >> "$summary_file"
    echo "" >> "$summary_file"
    
    # Node conditions that indicate issues
    echo "Node Issues:" >> "$summary_file"
    local node_issues=false
    local node_data_output
    node_data_output=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' 2>/dev/null)
    if [[ -n "$node_data_output" ]]; then
        while read -r node_data; do
            if echo "$node_data" | grep -q "Ready=False\|MemoryPressure=True\|DiskPressure=True\|PIDPressure=True\|NetworkUnavailable=True"; then
                echo "  ⚠ $node_data" >> "$summary_file"
                node_issues=true
            fi
        done <<< "$node_data_output"
    fi
    if [[ "$node_issues" == "false" ]]; then
        echo "  ✓ No critical node issues detected" >> "$summary_file"
    fi
    echo "" >> "$summary_file"
    
    # Pending pods summary
    echo "Resource Constraints:" >> "$summary_file"
    local pending_count=$(kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l)
    if [[ $pending_count -gt 0 ]]; then
        echo "  ⚠ $pending_count pod(s) in Pending state" >> "$summary_file"
        kubectl get pods --all-namespaces --field-selector=status.phase=Pending --no-headers 2>/dev/null | head -5 | while read -r line; do
            echo "    - $line" >> "$summary_file"
        done
        if [[ $pending_count -gt 5 ]]; then
            echo "    ... and $((pending_count - 5)) more" >> "$summary_file"
        fi
    else
        echo "  ✓ No pending pods" >> "$summary_file"
    fi
    echo "" >> "$summary_file"
    
    # Recent autoscaler events
    echo "Recent Cluster Autoscaler Activity:" >> "$summary_file"
    if [[ -f "${cluster_dir}/cluster-autoscaler-events.yaml" ]]; then
        local recent_events=$(kubectl get events --all-namespaces --sort-by='.lastTimestamp' 2>/dev/null | grep -i "scaled.*group\|autoscaler" | tail -5)
        if [[ -n "$recent_events" ]]; then
            echo "$recent_events" | while read -r event; do
                echo "  $event" >> "$summary_file"
            done
        else
            echo "  - Recent events found in file, but not in live query" >> "$summary_file"
        fi
    else
        echo "  - No recent autoscaler activity" >> "$summary_file"
    fi
    echo "" >> "$summary_file"
    
    # Recent Karpenter activity
    echo "Recent Karpenter Activity:" >> "$summary_file"
    if [[ -f "${cluster_dir}/karpenter-events.yaml" ]]; then
        local karpenter_events=$(kubectl get events --all-namespaces --sort-by='.lastTimestamp' 2>/dev/null | grep -i "karpenter\|provisioner\|nodepool\|nodeclaim" | tail -5)
        if [[ -n "$karpenter_events" ]]; then
            echo "$karpenter_events" | while read -r event; do
                echo "  $event" >> "$summary_file"
            done
        else
            echo "  - Recent events found in file, but not in live query" >> "$summary_file"
        fi
    else
        echo "  - No recent Karpenter activity" >> "$summary_file"
    fi
    echo "" >> "$summary_file"
    
    # Karpenter node provisioning status
    if kubectl get nodepools.karpenter.sh --no-headers 2>/dev/null | head -3 | while read -r line; do
        if [[ -n "$line" ]]; then
            echo "Karpenter NodePools:" >> "$summary_file"
            echo "  $line" >> "$summary_file"
        fi
    done 2>/dev/null; then
        echo "" >> "$summary_file"
    elif kubectl get provisioners.karpenter.sh --no-headers 2>/dev/null | head -3 | while read -r line; do
        if [[ -n "$line" ]]; then
            echo "Karpenter Provisioners:" >> "$summary_file"
            echo "  $line" >> "$summary_file"
        fi
    done 2>/dev/null; then
        echo "" >> "$summary_file"
    fi
    
    # Resource utilization summary
    echo "Resource Utilization:" >> "$summary_file"
    if kubectl top nodes --no-headers 2>/dev/null | while read -r node cpu memory; do
        echo "  $node: CPU=$cpu Memory=$memory" >> "$summary_file"
    done; then
        echo "" >> "$summary_file"
    else
        echo "  - Resource utilization data unavailable (metrics-server not available)" >> "$summary_file"
        echo "" >> "$summary_file"
    fi
}

function dump::__extract_helm_release_data() {
    local ns="$1"
    local secret_name="$2"
    local output_dir="$3"
    local file_prefix="$4"  # Optional prefix for output files (e.g., "helm-" or "")
    
    dump::__print_status "  \033[36m- Found Helm release secret: $secret_name\033[0m"
    
    local helm_data=$(kubectl get secret -n "$ns" "$secret_name" -o jsonpath='{.data.release}' 2>/dev/null)
    if [[ -n "$helm_data" ]]; then
        local safe_name=$(echo "$secret_name" | tr '.' '_')
        local temp_release=$(mktemp)
        
        if echo "$helm_data" | base64 -d | base64 -d | gunzip 2>/dev/null > "$temp_release"; then
            # Extract values and convert to YAML
            if jq -r '.chart.values // empty' "$temp_release" 2>/dev/null | yq -P > "${output_dir}/${file_prefix}${safe_name}-values.yaml" 2>/dev/null && [[ -s "${output_dir}/${file_prefix}${safe_name}-values.yaml" ]]; then
                dump::__print_status "    \033[32m✓ Helm values extracted for $secret_name\033[0m"
            else
                rm -f "${output_dir}/${file_prefix}${safe_name}-values.yaml"
                dump::__print_status "    \033[90m- No Helm values found in release data for $secret_name\033[0m"
            fi
            
            # Extract version information
            local chart_version=$(jq -r '.chart.metadata.version // empty' "$temp_release" 2>/dev/null)
            local app_version=$(jq -r '.chart.metadata.appVersion // empty' "$temp_release" 2>/dev/null)
            local release_version=$(jq -r '.version // empty' "$temp_release" 2>/dev/null)
            
            if [[ -n "$chart_version" || -n "$app_version" || -n "$release_version" ]]; then
                {
                    echo "# Helm Installation Information for $secret_name"
                    echo "# Generated: $(date)"
                    echo ""
                    [[ -n "$chart_version" ]] && echo "Chart Version: $chart_version"
                    [[ -n "$app_version" ]] && echo "App Version: $app_version"
                    [[ -n "$release_version" ]] && echo "Release Version: $release_version"
                    echo ""
                    echo "# For complete values, see: ${file_prefix}${safe_name}-values.yaml"
                } > "${output_dir}/${file_prefix}${safe_name}-info.txt"
                dump::__print_status "    \033[32m✓ Helm version information extracted for $secret_name\033[0m"
            fi
            
            # Clean up temp file
            rm -f "$temp_release"
            return 0  # Success
        else
            rm -f "$temp_release"
            dump::__print_status "    \033[31m✗ Failed to decode Helm release data for $secret_name\033[0m"
            return 1  # Failure
        fi
    else
        dump::__print_status "    \033[31m✗ Failed to extract Helm release data from secret $secret_name\033[0m"
        return 1  # Failure
    fi
}

# Execute dump::cmd when script is run directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    dump::cmd "$@"
fi
