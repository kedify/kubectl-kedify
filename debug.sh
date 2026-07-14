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
  so/scaledobject       Inspect ScaledObject metrics through its generated HPA or KPA
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

function debug::__get_pod_autoscaler() {
    local namespace="$1"
    local autoscaler_name="$2"
    local preferred_class="${3:-}"
    local hpa=""
    local kpa=""
    local hpa_error=""
    local kpa_error=""
	local error_dir=""

    if [[ -z "$autoscaler_name" || "$autoscaler_name" == "null" ]]; then
        echo "ScaledObject status.hpaName is not set" >&2
        return 1
    fi

	error_dir=$(mktemp -d)
	if hpa=$(kubectl get horizontalpodautoscalers.autoscaling "$autoscaler_name" -n "$namespace" -o json 2>"${error_dir}/hpa"); then
		hpa_error=$(<"${error_dir}/hpa")
		[[ -z "$hpa_error" ]] || printf '%s\n' "$hpa_error" >&2
	else
		hpa_error=$(<"${error_dir}/hpa")
        hpa=""
    fi

    # KPA deliberately uses the HPA-compatible autoscaling/v2 spec/status shape,
    # so the remaining debug logic can consume either resource without a private client.
	if kpa=$(kubectl get kedifypodautoscalers.autoscaling.kedify.io "$autoscaler_name" -n "$namespace" -o json 2>"${error_dir}/kpa"); then
		kpa_error=$(<"${error_dir}/kpa")
		[[ -z "$kpa_error" ]] || printf '%s\n' "$kpa_error" >&2
	else
		kpa_error=$(<"${error_dir}/kpa")
        kpa=""
    fi
	rm -f "${error_dir}/hpa" "${error_dir}/kpa"
	rmdir "$error_dir"

    if [[ -n "$hpa" && -n "$kpa" ]]; then
        echo "Both HPA and KPA '$autoscaler_name' exist in namespace '$namespace'; remove the stale autoscaler before debugging metrics" >&2
        return 1
    fi

    if [[ -n "$hpa" ]]; then
        case "$kpa_error" in
            *Forbidden*|*forbidden*|*Unauthorized*|*unauthorized*)
                echo "Warning: KPA lookup was forbidden; a same-named KPA conflict cannot be excluded" >&2
                ;;
        esac
    fi
    if [[ -n "$kpa" ]]; then
        case "$hpa_error" in
            *Forbidden*|*forbidden*|*Unauthorized*|*unauthorized*)
                echo "Warning: HPA lookup was forbidden; a same-named HPA conflict cannot be excluded" >&2
                ;;
        esac
    fi

    case "$preferred_class" in
        hpa)
            if [[ -z "$hpa" ]]; then
                echo "ScaledObject selects HPA '$autoscaler_name', but it was not found or is not readable in namespace '$namespace'" >&2
                [[ -n "$hpa_error" ]] && echo "HPA lookup: $hpa_error" >&2
                return 1
            fi
            printf '%s\n' "$hpa"
            return 0
            ;;
        kpa)
            if [[ -z "$kpa" ]]; then
                echo "ScaledObject selects KPA '$autoscaler_name', but it was not found or is not readable in namespace '$namespace'" >&2
                [[ -n "$kpa_error" ]] && echo "KPA lookup: $kpa_error" >&2
                return 1
            fi
            printf '%s\n' "$kpa"
            return 0
            ;;
    esac

    if [[ -n "$kpa" ]]; then
        printf '%s\n' "$kpa"
        return 0
    fi

    if [[ -n "$hpa" ]]; then
        printf '%s\n' "$hpa"
        return 0
    fi

    echo "Pod autoscaler '$autoscaler_name' was not found or is not readable as an HPA or KPA in namespace '$namespace'" >&2
    [[ -n "$hpa_error" ]] && echo "HPA lookup: $hpa_error" >&2
    [[ -n "$kpa_error" ]] && echo "KPA lookup: $kpa_error" >&2
    return 1
}

function debug::__resource_metric_value() {
    local autoscaler="$1"
    local metric="$2"
    local container_name="${3:-}"

    echo "$autoscaler" | jq --raw-output --arg metric "$metric" --arg container "$container_name" '
        [
          .spec.metrics[]? |
          if .type == "Resource" and .resource.name == $metric and $container == "" then
            {
              source: "resource",
              targetType: (.resource.target.type // ""),
              container: ""
            }
          elif .type == "ContainerResource" and
               .containerResource.name == $metric and
               ($container == "" or .containerResource.container == $container) then
            {
              source: "containerResource",
              targetType: (.containerResource.target.type // ""),
              container: (.containerResource.container // "")
            }
          else
            empty
          end
        ] as $targets |
        if ($targets | length) != 1 then
          empty
        else
          $targets[0] as $target |
          if $target.targetType == "Utilization" then
            "averageUtilization"
          elif $target.targetType == "AverageValue" then
            "averageValue"
          else
            empty
          end as $field |
          [
            .status.currentMetrics[]? |
            if $target.source == "resource" and
               .type == "Resource" and
               .resource.name == $metric then
              .resource.current[$field] // empty
            elif $target.source == "containerResource" and
                 .type == "ContainerResource" and
                 .containerResource.name == $metric and
                 .containerResource.container == $target.container then
              .containerResource.current[$field] // empty
            else
              empty
            end
          ] |
          if length == 1 then .[0] else empty end
        end
    '
}

function debug::__external_metric_value() {
    local autoscaler="$1"
    local metric="$2"

    echo "$autoscaler" | jq --raw-output --arg metric "$metric" '
        [
          .status.currentMetrics[]? |
          select(.external.metric.name == $metric) |
          (.external.current.averageValue // .external.current.value // empty)
        ][0] // empty
    '
}

function debug::__scaledobject() {
    local so="$1"
    local output_type="$2"
    local print_namespace="$3"
    local continue_on_resolution_error="${4:-false}"

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
    local container_name=""
    local hasStatusCurrentMetrics=""
    local val=""
    local hpa_index=0
    local api=""
    local autoscaling_class=""
    local autoscaler_kind=""

    so_name=$(echo "$so" | jq --raw-output '.metadata.name')
    hpa_name=$(echo "$so" | jq --raw-output '.status.hpaName')
    namespace=$(echo "$so" | jq --raw-output '.metadata.namespace')
    autoscaling_class=$(echo "$so" | jq --raw-output '.metadata.annotations["autoscaling.kedify.io/class"] // ""')
    if ! hpa=$(debug::__get_pod_autoscaler "$namespace" "$hpa_name" "$autoscaling_class"); then
        echo "Unable to inspect ScaledObject '$namespace/$so_name': its generated pod autoscaler could not be resolved" >&2
        if [[ "$continue_on_resolution_error" == "true" ]]; then
            return 0
        fi
        return 1
    fi
    autoscaler_kind=$(echo "$hpa" | jq --raw-output '.kind')
    default_trigger_name="$(debug::__no_trigger "$output_type")"
    trigger_count=$(echo "$so" | jq --raw-output '.spec.triggers | length')
    while [[ $i -lt $trigger_count ]]; do
        trigger_type=$(echo "$so" | jq --raw-output ".spec.triggers[$i].type")
        trigger_name=$(echo "$so" | jq --raw-output --arg default_trigger_name "$default_trigger_name" ".spec.triggers[$i].name // \$default_trigger_name")
        if [[ "$trigger_type" == "cpu" || "$trigger_type" == "memory" ]]; then
            index_offset=$((index_offset + 1))
            metric=$trigger_type
            container_name=$(echo "$so" | jq --raw-output ".spec.triggers[$i].metadata.containerName // empty")
            hasStatusCurrentMetrics=$(echo "$hpa" | jq --raw-output '.status.currentMetrics // [] | length')
            if [[ "$hasStatusCurrentMetrics" -eq 0 ]]; then
                val="$(debug::__no_value "$output_type")"
            else
                val=$(debug::__resource_metric_value "$hpa" "$metric" "$container_name")
                [[ -n "$val" ]] || val="$(debug::__no_value "$output_type")"
            fi
        else
            hpa_index=$((i - index_offset))
            metric=$(echo "$hpa" | jq --raw-output ".spec.metrics[$hpa_index].external.metric.name")
            if [[ "$autoscaler_kind" == "KedifyPodAutoscaler" ]]; then
                val=$(debug::__external_metric_value "$hpa" "$metric")
                [[ -n "$val" ]] || val="$(debug::__no_value "$output_type")"
            else
                api="/apis/external.metrics.k8s.io/v1beta1/namespaces/${namespace}/${metric}?labelSelector=scaledobject.keda.sh%2Fname%3D${so_name}"
                val=$(kubectl get --raw "$api" | jq --raw-output '.items[].value')
            fi
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
                debug::__scaledobject "$item" "$output_type" "$print_namespace" true
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
