#!/usr/bin/env bash

# insights.sh - ScaledObject analysis and insights functionality for kubectl-kedify

# Initialize global variables for problem tracking
insights_all_problems=""
insights_problem_resources_count=0
insights_total_problems_count=0

function insights::__failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}

function insights::__configure_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        emulate -L ksh
        setopt typeset_silent
    fi

    set -euo pipefail
    if [[ -n "${BASH_VERSION:-}" ]]; then
        set -E
        trap 'insights::__failure ${LINENO} "$BASH_COMMAND"' ERR
    fi
}

# Helper function to add problems
function insights::__add_problem() {
    local resource_key="$1"
    local message="$2"
    
    # Use a simple approach compatible with older bash versions
    # Store problems in a format: "RESOURCE_NAME|||MESSAGE"
    local problem_entry="${resource_key}|||${message}"
    
    # Check if this is the first problem for this resource
    if ! echo "$insights_all_problems" | grep -q "^${resource_key}|||"; then
        insights_problem_resources_count=$((insights_problem_resources_count + 1))
    fi
    
    # Add the problem to our list
    if [[ -z "$insights_all_problems" ]]; then
        insights_all_problems="$problem_entry"
    else
        insights_all_problems="$insights_all_problems"$'\n'"$problem_entry"
    fi
    
    insights_total_problems_count=$((insights_total_problems_count + 1))
}

# Check for polling interval issues when minReplicaCount > 0
function insights::__check_polling_interval_with_min_replicas() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    local min_replicas=""
    local idle_replicas=""
    local polling_interval=""
    min_replicas=$(echo "$so_json" | jq -r '.spec.minReplicaCount // 0')
    idle_replicas=$(echo "$so_json" | jq -r '.spec.idleReplicaCount // "null"')
    polling_interval=$(echo "$so_json" | jq -r '.spec.pollingInterval // 30')
    
    # Check for polling interval issue - ensure min_replicas is numeric and > 0
    if [[ "$min_replicas" =~ ^[0-9]+$ && "$min_replicas" -gt 0 ]]; then
        # Special case: if idleReplicaCount is 0 and minReplicaCount > 0, this is correct
        if [[ "$idle_replicas" == "0" ]]; then
            return
        fi
        
        # Check if any trigger has useCachedMetrics set to true
        local has_cached_metrics="false"
        if echo "$so_json" | jq -r '.spec.triggers[]?.useCachedMetrics // false' | grep -q "true"; then
            has_cached_metrics="true"
        fi
        
        # If any trigger uses cached metrics, pollingInterval is valid
        if [[ "$has_cached_metrics" == "true" ]]; then
            return
        fi
        
        local resource_name=""
        if [[ "$all_namespaces" == true ]]; then
            resource_name="${so_namespace}/${so_name}"
        else
            resource_name="${so_name}"
        fi
        
        if [[ "$idle_replicas" == "null" && "$polling_interval" != "30" ]] || [[ "$idle_replicas" != "null" && "$idle_replicas" != "0" && "$polling_interval" != "30" ]]; then
            # pollingInterval is set to non-default value but minReplicas > 0
            insights::__add_problem "$resource_name" "pollingInterval (${polling_interval}s) has no effect when minReplicaCount > 0. Consider removing pollingInterval setting."
        elif [[ "$polling_interval" == "30" && "$idle_replicas" != "0" ]]; then
            # pollingInterval is default but minReplicas > 0 and not the special case
            insights::__add_problem "$resource_name" "pollingInterval has no effect when minReplicaCount > 0. Consider removing pollingInterval setting."
        fi
    fi
}

# Check for low polling interval values
function insights::__check_low_polling_interval() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    local polling_interval=""
    polling_interval=$(echo "$so_json" | jq -r '.spec.pollingInterval // "null"')
    
    # Only check if pollingInterval is explicitly set and is numeric
    if [[ "$polling_interval" != "null" && "$polling_interval" =~ ^[0-9]+$ && "$polling_interval" -le 10 ]]; then
        local resource_name=""
        if [[ "$all_namespaces" == true ]]; then
            resource_name="${so_namespace}/${so_name}"
        else
            resource_name="${so_name}"
        fi
        
        insights::__add_problem "$resource_name" "pollingInterval (${polling_interval}s) is set to a very low value. Be careful as this might overload your services."
    fi
}

# Check for missing fallback configuration
function insights::__check_missing_fallback() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    # Check if fallback section exists
    local has_fallback=""
    has_fallback=$(echo "$so_json" | jq -r '.spec.fallback // "null"')
    if [[ "$has_fallback" != "null" ]]; then
        # Fallback is already configured, skip check
        return
    fi
    
    # Check if ScaledObject has only CPU/memory triggers or Value-type triggers
    local has_supported_triggers=false
    
    while IFS= read -r trigger; do
        local trigger_type=""
        local metric_type=""
        trigger_type=$(echo "$trigger" | jq -r '.type')
        metric_type=$(echo "$trigger" | jq -r '.metricType // "AverageValue"')
        
        # Skip CPU and memory scalers (not supported for fallback)
        if [[ "$trigger_type" == "cpu" || "$trigger_type" == "memory" ]]; then
            continue
        fi
        
        # Skip Value-type metrics (not supported for fallback)
        if [[ "$metric_type" == "Value" ]]; then
            continue
        fi
        
        # If we reach here, this trigger supports fallback
        has_supported_triggers=true
        break
        
    done < <(echo "$so_json" | jq -c '.spec.triggers[]')
    
    # Only suggest fallback if there are triggers that support it
    if [[ "$has_supported_triggers" == true ]]; then
        local resource_name=""
        if [[ "$all_namespaces" == true ]]; then
            resource_name="${so_namespace}/${so_name}"
        else
            resource_name="${so_name}"
        fi
        
        insights::__add_problem "$resource_name" "No fallback configuration specified. Consider adding a fallback section to handle scaler failures gracefully."
    fi
}

# Help function for insights command
function insights::__print_help() {
    cat << EOF

Usage: kubectl kedify insights [-n namespace] [-A|--all-namespaces]

Analyzes ScaledObjects for potential configuration issues and provides actionable insights.

Options:
  -n, --namespace NAMESPACE    Analyze ScaledObjects in the specified namespace
  -A, --all-namespaces         Analyze ScaledObjects across all namespaces

  -h, --help                   Show this help message

Examples:
  kubectl kedify insights                        ... analyzes ScaledObjects in current namespace
  kubectl kedify insights -A                     ... analyzes ScaledObjects in all namespaces
  kubectl kedify insights -n myapp               ... analyzes ScaledObjects in specific namespace

The insights command checks for:
  • pollingInterval effectiveness when minReplicaCount > 0
  • Low pollingInterval values that might overload services
  • Missing fallback configuration for supported scalers

EOF
}

# Main insights command handler
function insights::__cmd_impl() {
    local namespace=""
    local all_namespaces=false

    insights_all_problems=""
    insights_problem_resources_count=0
    insights_total_problems_count=0
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                if [[ $# -lt 2 ]]; then
                    echo "Error: -n|--namespace requires a value"
                    echo ""
                    insights::__print_help
                    exit 1
                fi
                namespace="$2"
                shift 2
                ;;
            -A|--all-namespaces)
                all_namespaces=true
                shift
                ;;
            -h|--help)
                insights::__print_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo ""
                insights::__print_help
                exit 1
                ;;
        esac
    done
    
    # Build kubectl command
    local kubectl_cmd="${KUBECTL} get scaledobjects"
    if [[ "$all_namespaces" == true ]]; then
        kubectl_cmd="$kubectl_cmd -A"
    elif [[ -n "$namespace" ]]; then
        kubectl_cmd="$kubectl_cmd -n $namespace"
    else
        # If no namespace specified, get the current namespace from context
        namespace=$(kubectl config view --minify --output 'jsonpath={..namespace}' 2>/dev/null || echo "default")
        # If the namespace is empty, default to "default"
        if [[ -z "$namespace" ]]; then
            namespace="default"
        fi
    fi
    kubectl_cmd="$kubectl_cmd -o json"
    
    # Call the analyze function
    insights::__analyze "$namespace" "$all_namespaces" "$kubectl_cmd"
}

function insights::cmd() (
    insights::__configure_shell
    insights::__cmd_impl "$@"
)

# Main analysis function
function insights::__analyze() {
    local namespace="$1"
    local all_namespaces="$2"
    local kubectl_cmd="$3"
    
    if command -v figlet >/dev/null 2>&1; then
        figlet insights
    else
        echo "INSIGHTS"
    fi
    
    # Determine scope message
    local scope_msg=""
    if [[ "$all_namespaces" == true ]]; then
        scope_msg="all namespaces"
    else
        scope_msg="namespace '$namespace'"
    fi
    
    # Show initial message
    printf "\nAnalyzing ScaledObjects in %s for potential issues" "$scope_msg"
    
    # Check if ScaledObjects CRD exists first
    if ! kubectl api-resources --api-group=keda.sh | grep -q scaledobjects; then
        printf "\r\033[2K"
        echo "Error: ScaledObjects CRD not found. Make sure Kedify/KEDA is installed." >&2
        exit 1
    fi
    
    # Get ScaledObjects
    local scaledobjects_json
    scaledobjects_json=$(eval "$kubectl_cmd" 2>/dev/null) || {
        printf "\r\033[2K"
        echo "Error: Unable to retrieve ScaledObjects. Make sure KEDA is installed and you have proper permissions." >&2
        exit 1
    }
    
    local total_count=""
    total_count=$(echo "$scaledobjects_json" | jq -r '.items | length')
    if [[ "$total_count" == "0" ]]; then
        printf "\r\033[2K"
        echo "No ScaledObjects found in $scope_msg."
        exit 0
    fi
    
    # Simple progress indicator - show dots
    local analyzed_count=0
    printf " ."
    
    # Analyze each ScaledObject
    while IFS= read -r so_json; do
        local so_name=""
        local so_namespace=""
        so_name=$(echo "$so_json" | jq -r '.metadata.name')
        so_namespace=$(echo "$so_json" | jq -r '.metadata.namespace')
        
        # Run all checks
        insights::__check_polling_interval_with_min_replicas "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        insights::__check_low_polling_interval "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        insights::__check_missing_fallback "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        
        # Show progress
        analyzed_count=$((analyzed_count+1))
        if [[ $((analyzed_count % 3)) -eq 0 ]]; then
            printf "."
        fi
        
    done < <(echo "$scaledobjects_json" | jq -c '.items[]')
    
    # Clear the analysis line and show results
    printf "\r\033[2K"
    
    # Print summary using printf to avoid escape sequence issues
    printf "\033[2;35;49mSummary:\033[0m Total ScaledObjects: %d | ScaledObjects with issues: %d | Total issues found: %d\n" "$total_count" "$insights_problem_resources_count" "$insights_total_problems_count"
    
    if [[ "$insights_problem_resources_count" -gt 0 ]]; then
        printf "\n\033[2;35;49mISSUES FOUND:\033[0m\n"
        
        # Process problems and group by resource
        local current_resource=""
        while IFS= read -r line; do
            # Skip empty lines
            if [[ -z "$line" ]]; then
                continue
            fi
            
            # Parse the line manually to handle the ||| delimiter properly
            local resource_name="${line%%|||*}"
            local message="${line#*|||}"
            
            # Skip malformed entries
            if [[ -z "$resource_name" || -z "$message" || "$resource_name" == "$line" ]]; then
                continue
            fi
            
            if [[ "$resource_name" != "$current_resource" ]]; then
                if [[ -n "$current_resource" ]]; then
                    echo  # Add blank line between resources
                fi
                printf "\n\033[1;33m%s:\033[0m\n" "$resource_name"
                current_resource="$resource_name"
            fi
            printf "    - %s\n" "$message"
        done < <(echo "$insights_all_problems" | grep -v '^$' | sort)
    else
        printf "\n\033[2;35;49m✓ No issues found!\033[0m\n"
    fi
}
