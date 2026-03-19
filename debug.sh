#!/usr/bin/env bash

function debug::__failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}

function debug::__configure_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        emulate -L ksh
        setopt typeset_silent
    fi

    set -euo pipefail
    if [[ -n "${BASH_VERSION:-}" ]]; then
        set -E
        trap 'debug::__failure ${LINENO} "$BASH_COMMAND"' ERR
    fi
}

function debug::__aggregate_interceptor_queue() {
    local output_type="$1"
    local mode="$2"

    local cmd=""
    case $output_type in
        json)
            cmd="jq '.'"
            ;;
        yaml)
            cmd="yq e -P"
            ;;
        *)
            cmd="$(debug::__addon_queue_structured_output "$mode") | column -t -s $'\t'"
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

function debug::__addon_queue_structured_output() {
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

function debug::__print_usage() {
    cat << EOF

Usage: kubectl kedify debug <command> [options]

Available commands:
  so/scaledobject       Inspect ScaledObject resource
  httpaddon             Verify HTTP Addon setup and current configuration

Options:
  -o, --output FORMAT   Output format (json, yaml) - for supported commands
  -i, --individual      Show individual queue sizes per interceptor instead of aggregating
  -w, --watch           Continuously watch and update every second
  -h, --help            Show this help message

Examples:
  kubectl kedify debug scaledobject -n default foo     ... inspect ScaledObject resource named 'foo' in the 'default' namespace
  kubectl kedify debug scaledobject --watch            ... continuously watch all ScaledObjects and update every second
  kubectl kedify debug httpaddon queue                 ... check the queue sizes in each HTTP addon interceptor pod
  kubectl kedify debug httpaddon queue --watch         ... continuously watch HTTP addon queue sizes and update every second

EOF
}

function debug::__structured_output() {
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

function debug::__httpaddon_cmd() {
    if [[ $# -eq 0 ]]; then
        echo "No sub-command provided, available sub-commands are:"
        echo "  queue"
        echo ""
        debug::__print_usage
        exit 1
    fi
    local sub_command="$1"
    shift

    local ns=""
    if kubectl get kedify -A > /dev/null 2>&1; then
        ns=$(kubectl get kedify -A -o json | jq -r '.items[0].metadata.namespace')
    fi
    local output_type=""
    local mode="aggregated"
    local watch="false"
    local next="false"
    for o in "$@"; do
        if [[ "$next" == "true" ]]; then
            output_type="$o"
            next="false"
            continue
        fi
        case $o in
            -o|--output)
                next="true"
                ;;
            -o=*|--output=*)
                output_type="${o#*=}"
                ;;
            -o*)
                output_type="${o#-o}"
                ;;
            --output*)
                output_type="${o#--output}"
                ;;
            -i|--individual)
                mode="individual"
                ;;
            -w|--watch)
                watch="true"
                ;;
            -h|--help)
                debug::__print_usage
                exit 0
                ;;
            *)
                echo "Unknown flag: $o"
                echo "" 
                echo "Available flags:"
                echo "  -o|--output         ... output format (json, yaml)"
                echo "  -i|--individual     ... show individual queue sizes per interceptor instead of aggregating"
                echo "  -w|--watch          ... continuously watch and update every second"
                echo "  -h|--help           ... show this help message"
                debug::__print_usage
                exit 1
                ;;
        esac
    done
    case $sub_command in
        queue)
            if [[ "$watch" == "true" ]]; then
                while true; do
                    output=$(kubectl get pods -l app.kubernetes.io/name=http-add-on -l app.kubernetes.io/component=interceptor -n "$ns" -o json | jq -r '.items[].metadata.name' | while read -r pod; do
                        kubectl get --raw "/api/v1/namespaces/$ns/pods/$pod/proxy/queue" | jq -r --arg pod "$pod" '. | {name: $pod, queue: .}'
                    done | debug::__aggregate_interceptor_queue "$output_type" "$mode")
                    clear
                    echo "$(date): HTTP Add-on Queue Status (Press Ctrl+C to stop)"
                    echo ""
                    echo "$output"
                    sleep 1
                done
            else
                kubectl get pods -l app.kubernetes.io/name=http-add-on -l app.kubernetes.io/component=interceptor -n "$ns" -o json | jq -r '.items[].metadata.name' | while read -r pod; do
                    kubectl get --raw "/api/v1/namespaces/$ns/pods/$pod/proxy/queue" | jq -r --arg pod "$pod" '. | {name: $pod, queue: .}'
                done | debug::__aggregate_interceptor_queue "$output_type" "$mode"
            fi
            ;;
        *)
            echo "Unknown sub-command: \"$sub_command\""
            debug::__print_usage
            exit 1
            ;;
    esac
}

function debug::__no_value() {
    local output_type="$1"
    case "$output_type" in
        json|yaml)
            echo "0"
            ;;
        *)
            echo "<none>"
            ;;
    esac
}

function debug::__no_trigger() {
    local output_type="$1"
    case "$output_type" in
        json|yaml)
            echo ""
            ;;
        *)
            echo "<none>"
            ;;
    esac
}

function debug::__scaledobject() {
    local so="$1"
    local output_type="$2"
    local print_namespace="$3"

    local so_name=""
    local hpa_name=""
    local namespace=""
    local hpa=""
    local trigger_count=0
    local index_offset=0
    local i=0
    local default_trigger_name=""
    local trigger_type=""
    local trigger_name=""
    local metric=""
    local metricType=""
    local hasStatusCurrentMetrics=""
    local val=""
    local hpa_index=0
    local api=""

    so_name=$(echo "$so" | jq --raw-output '.metadata.name')
    hpa_name=$(echo "$so" | jq --raw-output '.status.hpaName')
    namespace=$(echo "$so" | jq --raw-output '.metadata.namespace')
    hpa=$(kubectl get hpa "$hpa_name" -n "$namespace" -o json)
    default_trigger_name="$(debug::__no_trigger "$output_type")"
    trigger_count=$(echo "$so" | jq --raw-output '.spec.triggers | length')
    while [[ $i -lt $trigger_count ]]; do
        trigger_type=$(echo "$so" | jq --raw-output ".spec.triggers[$i].type")
        trigger_name=$(echo "$so" | jq --raw-output --arg default_trigger_name "$default_trigger_name" ".spec.triggers[$i].name // \$default_trigger_name")
        if [[ "$trigger_type" == "cpu" || "$trigger_type" == "memory" ]]; then
            index_offset=$((index_offset + 1))
            metric=$trigger_type
            metricType=$(echo "$so" | jq --raw-output ".spec.triggers[$i].metricType")
            hasStatusCurrentMetrics=$(echo "$hpa" | jq --raw-output '.status.currentMetrics | length')
            if [[ "$hasStatusCurrentMetrics" -eq 0 ]]; then
                val="$(debug::__no_value "$output_type")"
            else
                val=$(echo "$hpa" | jq --raw-output ".status.currentMetrics[] | select(.resource.name == \"$metric\") | .resource.current.average$metricType")
            fi
        else
            hpa_index=$((i - index_offset))
            metric=$(echo "$hpa" | jq --raw-output ".spec.metrics[$hpa_index].external.metric.name")
            api="/apis/external.metrics.k8s.io/v1beta1/namespaces/${namespace}/${metric}?labelSelector=scaledobject.keda.sh%2Fname%3D${so_name}"
            val=$(kubectl get --raw "$api" | jq --raw-output '.items[].value')
        fi
        case $output_type in
            json|yaml)
                jq -cn \
                    --arg namespace "$namespace" \
                    --arg name "$so_name" \
                    --arg trigger_name "$trigger_name" \
                    --arg trigger_type "$trigger_type" \
                    --arg metric "$metric" \
                    --arg value "$val" \
                    '{
                        namespace: $namespace,
                        name: $name,
                        triggerName: $trigger_name,
                        triggerType: $trigger_type,
                        metric: $metric,
                        value: ($value | tonumber? // .)
                    }'
                ;;
            wide)
                if [[ "$print_namespace" == "true" ]]; then
                    echo "$namespace $so_name $i $trigger_name $trigger_type $metric $val"
                else
                    echo "$so_name $i $trigger_name $trigger_type $metric $val"
                fi
                ;;
            *)
                if [[ "$print_namespace" == "true" ]]; then
                    echo "$namespace $so_name $trigger_type $val"
                else
                    echo "$so_name $trigger_type $val"
                fi
                ;;
        esac
        i=$((i + 1))
    done
}

function debug::__scaledobject_cmd() {
    local filtered_flags=()
    local output_type=""
    local next="false"
    local print_namespace="false"
    local watch="false"

    for o in "$@"; do
        if [[ "$next" == "true" ]]; then
            output_type="$o"
            next="false"
            continue
        fi
        case $o in
            -o|--output)
                next="true"
                ;;
            -o=*|--output=*)
                output_type="${o#*=}"
                ;;
            -o*)
                output_type="${o#-o}"
                ;;
            --output*)
                output_type="${o#--output}"
                ;;
            -w|--watch)
                watch="true"
                ;;
            --all-namespaces|-A)
                print_namespace="true"
                filtered_flags+=("$o")
                ;;
            -h|--help)
                debug::__print_usage
                exit 0
                ;;
            *)
                # Check if it's a flag (starts with -)
                if [[ "$o" == -* ]]; then
                    echo "Unknown flag: $o"
                    echo ""
                    echo "Available flags:"
                    echo "  -o|--output         ... output format (json, yaml, wide)"
                    echo "  -w|--watch          ... continuously watch and update every second"
                    echo "  -A|--all-namespaces ... list resources from all namespaces"
                    echo ""
                    echo "  -h|--help           ... show this help message"
                    debug::__print_usage
                    exit 1
                else
                    filtered_flags+=("$o")
                fi
                ;;
        esac
    done

    if [[ "$watch" == "true" ]]; then
        while true; do
            if [[ ${#filtered_flags[@]} -eq 0 ]]; then
                output=$(debug::__execute_scaledobject_once "$output_type" "$print_namespace")
            else
                output=$(debug::__execute_scaledobject_once "$output_type" "$print_namespace" "${filtered_flags[@]}")
            fi
            clear
            echo "$(date): ScaledObject Status (Press Ctrl+C to stop)"
            echo ""
            echo "$output"
            sleep 1
        done
    else
        if [[ ${#filtered_flags[@]} -eq 0 ]]; then
            debug::__execute_scaledobject_once "$output_type" "$print_namespace"
        else
            debug::__execute_scaledobject_once "$output_type" "$print_namespace" "${filtered_flags[@]}"
        fi
    fi
}

function debug::__execute_scaledobject_once() {
    local output_type="$1"
    local print_namespace="$2"
    shift 2
    local filtered_flags=("$@")

    local output=""
    if [[ ${#filtered_flags[@]} -eq 0 ]]; then
        if ! output=$(kubectl get scaledobjects -o json 2>&1); then
            echo "Error: Failed to get ScaledObjects. Make sure KEDA is installed and you have the necessary permissions."
            exit 1
        fi
    else
        if ! output=$(kubectl get scaledobjects "${filtered_flags[@]}" -o json 2>&1); then
            # Check if it's a "not found" error
            if echo "$output" | grep -q "not found"; then
                # Extract the resource name from the error message
                local resource_name=""
                resource_name=$(echo "$output" | sed -n 's/.*scaledobjects.keda.sh "\([^"]*\)" not found.*/\1/p')
                if [[ -n "$resource_name" ]]; then
                    echo "ScaledObject \"$resource_name\" not found"
                else
                    echo "ScaledObject not found"
                fi
            else
                echo "Error: $output"
            fi
            exit 1
        fi
    fi
    local kind=""
    local formatting_cmd=""
    local header=""
    kind=$(echo "$output" | jq -r '.kind')
    case $output_type in
        json)
            formatting_cmd="$(debug::__structured_output)"
            ;;
        yaml)
            formatting_cmd="$(debug::__structured_output) | yq e -P"
            ;;
        wide)
            formatting_cmd="column -t"
            if [[ "$print_namespace" == "true" ]]; then
                header="NAMESPACE NAME INDEX TRIGGER_NAME TYPE METRIC VALUE"
            else
                header="NAME INDEX TRIGGER_NAME TYPE METRIC VALUE"
            fi
            ;;
        *)
            formatting_cmd="column -t"
            if [[ "$print_namespace" == "true" ]]; then
                header="NAMESPACE NAME TYPE VALUE"
            else
                header="NAME TYPE VALUE"
            fi
            ;;
    esac
    (
    if [[ -n "$header" ]]; then
        echo "$header"
    fi
    case $kind in
        "List")
            echo "$output" | jq -c '.items[]' | while read -r item; do
            debug::__scaledobject "$item" "$output_type" "$print_namespace"
        done
        ;;
    "ScaledObject")
        debug::__scaledobject "$output" "$output_type" "$print_namespace"
        ;;
    *)
        echo "Unknown kind: $kind"
        exit 1
        ;;
esac
) | eval "$formatting_cmd"
}

function debug::__cmd_impl() {
    if [[ $# -eq 0 ]]; then
        debug::__print_usage
        exit 1
    fi

    case $1 in
        so|scaledobject)
            debug::__scaledobject_cmd "${@:2}"
            ;;
        httpaddon)
            debug::__httpaddon_cmd "${@:2}"
            ;;
        *)
            echo "Unknown sub-command: \"$1\""
            debug::__print_usage
            exit 1
            ;;
    esac
}

function debug::cmd() (
    debug::__configure_shell
    debug::__cmd_impl "$@"
)
