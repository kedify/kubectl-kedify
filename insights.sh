#!/usr/bin/env bash

# insights.sh - ScaledObject analysis and insights functionality for kubectl-kedify

set -euo pipefail

# Initialize global variables for problem tracking
insights_all_problems=""
insights_problem_resources_count=0
insights_total_problems_count=0

# Helper function to add problems
insights_add_problem() {
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
insights_check_polling_interval_with_min_replicas() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    local min_replicas=$(echo "$so_json" | jq -r '.spec.minReplicaCount // 0')
    local idle_replicas=$(echo "$so_json" | jq -r '.spec.idleReplicaCount // "null"')
    local polling_interval=$(echo "$so_json" | jq -r '.spec.pollingInterval // 30')
    
    # Check for polling interval issue
    if [[ "$min_replicas" -gt 0 ]]; then
        # Special case: if idleReplicaCount is 0 and minReplicaCount > 0, this is correct
        if [[ "$idle_replicas" == "0" ]]; then
            return
        fi
        
        # Check if any trigger has useCachedMetrics set to true
        local has_cached_metrics=$(echo "$so_json" | jq -r '.spec.triggers[]?.useCachedMetrics // false' | grep -q "true" && echo "true" || echo "false")
        
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
        
        if [[ "$idle_replicas" == "null" && "$polling_interval" -ne 30 ]] || [[ "$idle_replicas" != "null" && "$idle_replicas" != "0" && "$polling_interval" -ne 30 ]]; then
            # pollingInterval is set to non-default value but minReplicas > 0
            insights_add_problem "$resource_name" "pollingInterval (${polling_interval}s) has no effect when minReplicaCount > 0. Consider removing pollingInterval setting."
        elif [[ "$polling_interval" -eq 30 && ("$idle_replicas" == "null" || ("$idle_replicas" != "null" && "$idle_replicas" != "0")) ]]; then
            # pollingInterval is default but minReplicas > 0 and not the special case
            insights_add_problem "$resource_name" "pollingInterval has no effect when minReplicaCount > 0. Consider removing pollingInterval setting."
        fi
    fi
}

# Check for low polling interval values
insights_check_low_polling_interval() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    local polling_interval=$(echo "$so_json" | jq -r '.spec.pollingInterval // "null"')
    
    # Only check if pollingInterval is explicitly set
    if [[ "$polling_interval" != "null" && "$polling_interval" -le 10 ]]; then
        local resource_name=""
        if [[ "$all_namespaces" == true ]]; then
            resource_name="${so_namespace}/${so_name}"
        else
            resource_name="${so_name}"
        fi
        
        insights_add_problem "$resource_name" "pollingInterval (${polling_interval}s) is set to a very low value. Be careful as this might overload your services."
    fi
}

# Check for missing fallback configuration
insights_check_missing_fallback() {
    local so_json="$1"
    local so_name="$2"
    local so_namespace="$3"
    local all_namespaces="$4"
    
    # Check if fallback section exists
    local has_fallback=$(echo "$so_json" | jq -r '.spec.fallback // "null"')
    if [[ "$has_fallback" != "null" ]]; then
        # Fallback is already configured, skip check
        return
    fi
    
    # Check if ScaledObject has only CPU/memory triggers or Value-type triggers
    local triggers=$(echo "$so_json" | jq -r '.spec.triggers[]')
    local has_supported_triggers=false
    
    while IFS= read -r trigger; do
        local trigger_type=$(echo "$trigger" | jq -r '.type')
        local metric_type=$(echo "$trigger" | jq -r '.metricType // "AverageValue"')
        
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
        
        insights_add_problem "$resource_name" "No fallback configuration specified. Consider adding a fallback section to handle scaler failures gracefully."
    fi
}

# Main insights function
insights_analyze() {
    local namespace="$1"
    local all_namespaces="$2"
    local kubectl_cmd="$3"
    
    figlet insights
    
    # Determine scope message
    local scope_msg=""
    if [[ "$all_namespaces" == true ]]; then
        scope_msg="all namespaces"
    else
        scope_msg="namespace '$namespace'"
    fi
    
    # Show initial message
    printf "\nAnalyzing ScaledObjects in %s for potential issues" "$scope_msg"
    
    # Get ScaledObjects
    local scaledobjects_json=$(eval "$kubectl_cmd" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        printf "\r\033[2K"
        echo "Error: Unable to retrieve ScaledObjects. Make sure KEDA is installed."
        exit 1
    fi
    
    local total_count=$(echo "$scaledobjects_json" | jq -r '.items | length')
    if [[ "$total_count" -eq 0 ]]; then
        printf "\r\033[2K"
        echo "No ScaledObjects found."
        exit 0
    fi
    
    # Simple progress indicator - show dots
    local analyzed_count=0
    printf " ."
    
    # Analyze each ScaledObject
    while IFS= read -r so_json; do
        local so_name=$(echo "$so_json" | jq -r '.metadata.name')
        local so_namespace=$(echo "$so_json" | jq -r '.metadata.namespace')
        
        # Run all checks
        insights_check_polling_interval_with_min_replicas "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        insights_check_low_polling_interval "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        insights_check_missing_fallback "$so_json" "$so_name" "$so_namespace" "$all_namespaces"
        
        # Show progress
        ((analyzed_count++))
        if [[ $((analyzed_count % 3)) -eq 0 ]]; then
            printf "."
        fi
        
    done < <(echo "$scaledobjects_json" | jq -c '.items[]')
    
    # Clear the analysis line and show results
    printf "\r\033[2K"
    
    # Print summary using printf to avoid escape sequence issues
    printf "\033[2;35;49mSummary:\033[0m Total ScaledObjects: %d | ScaledObjects with issues: %d | Total issues found: %d\n" "$total_count" "$insights_problem_resources_count" "$insights_total_problems_count"
    
    if [[ "$insights_problem_resources_count" -gt 0 ]]; then
        printf "\n\033[2;35;49mIssues found:\033[0m\n"
        
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
