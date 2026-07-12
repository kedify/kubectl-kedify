#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_MODE=""
REAL_JQ_BIN=""

function kubectl() {
    local args="$*"

    case "$MOCK_MODE" in
        hpa)
            if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
                echo '{"apiVersion":"autoscaling/v2","kind":"HorizontalPodAutoscaler"}'
                return 0
            fi
            ;;
        kpa)
            if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
                return 1
            fi
            if [[ "$args" == "get kedifypodautoscalers.autoscaling.kedify.io keda-hpa-orders -n tenant-a -o json" ]]; then
                echo '{"apiVersion":"autoscaling.kedify.io/v1alpha1","kind":"KedifyPodAutoscaler"}'
                return 0
            fi
            ;;
        conflict)
            if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
                echo '{"apiVersion":"autoscaling/v2","kind":"HorizontalPodAutoscaler"}'
                return 0
            fi
            if [[ "$args" == "get kedifypodautoscalers.autoscaling.kedify.io keda-hpa-orders -n tenant-a -o json" ]]; then
                echo '{"apiVersion":"autoscaling.kedify.io/v1alpha1","kind":"KedifyPodAutoscaler"}'
                return 0
            fi
            ;;
        hpa_kpa_forbidden)
            if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
                echo '{"apiVersion":"autoscaling/v2","kind":"HorizontalPodAutoscaler"}'
                return 0
            fi
            if [[ "$args" == "get kedifypodautoscalers.autoscaling.kedify.io keda-hpa-orders -n tenant-a -o json" ]]; then
                echo 'Error from server (Forbidden): kedifypodautoscalers.autoscaling.kedify.io is forbidden' >&2
                return 1
            fi
            ;;
        kpa_status)
            if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
                echo 'Error from server (NotFound): horizontalpodautoscaler not found' >&2
                return 1
            fi
            if [[ "$args" == "get kedifypodautoscalers.autoscaling.kedify.io keda-hpa-orders -n tenant-a -o json" ]]; then
                cat <<'EOF'
{"apiVersion":"autoscaling.kedify.io/v1alpha1","kind":"KedifyPodAutoscaler","spec":{"metrics":[{"type":"External","external":{"metric":{"name":"queue_depth"}}}]},"status":{"currentMetrics":[{"type":"Resource","resource":{"name":"cpu","current":{"averageUtilization":55,"averageValue":"100m"}}},{"type":"ContainerResource","containerResource":{"name":"memory","container":"worker","current":{"averageValue":"128Mi"}}},{"type":"External","external":{"metric":{"name":"queue_depth"},"current":{"averageValue":"7"}}}]}}
EOF
                return 0
            fi
            ;;
        kpa_warning)
			if [[ "$args" == "get horizontalpodautoscalers.autoscaling keda-hpa-orders -n tenant-a -o json" ]]; then
				echo 'Error from server (NotFound): horizontalpodautoscaler not found' >&2
				return 1
			fi
			if [[ "$args" == "get kedifypodautoscalers.autoscaling.kedify.io keda-hpa-orders -n tenant-a -o json" ]]; then
				echo 'Warning: server-side deprecation notice' >&2
				echo '{"apiVersion":"autoscaling.kedify.io/v1alpha1","kind":"KedifyPodAutoscaler"}'
				return 0
			fi
			;;
		count_empty)
			if [[ "$args" == "get pods -n empty -o name" ]]; then
				return 0
			fi
			if [[ "$args" == "get pods -n empty --no-headers" ]]; then
				echo 'No resources found in empty namespace.'
				return 0
			fi
			;;
        dump)
            case "$args" in
                "get crd kedifypodautoscalers.autoscaling.kedify.io -o yaml")
                    echo 'kind: CustomResourceDefinition'
                    return 0
                    ;;
                "get kedifypodautoscalers.autoscaling.kedify.io -n tenant-a -o json")
                    echo '{"items":[{"metadata":{"name":"keda-hpa-orders"}}]}'
                    return 0
                    ;;
                "get kedifypodautoscalers.autoscaling.kedify.io -n tenant-a -o yaml")
                    echo 'kind: KedifyPodAutoscalerList'
                    return 0
                    ;;
                "get events -n tenant-a --field-selector involvedObject.kind=KedifyPodAutoscaler --sort-by=.lastTimestamp -o yaml")
                    echo 'kind: EventList'
                    return 0
                    ;;
				*" -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o name")
					echo 'deployment.apps/resource-found'
                    return 0
                    ;;
                "get deployments -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o yaml"|\
                "get services -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o yaml"|\
                "get endpoints -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o yaml"|\
                "get endpointslices.discovery.k8s.io -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o yaml")
                    echo 'kind: List'
                    return 0
                    ;;
                "get deployments -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o json")
                    echo '{"items":[{"metadata":{"name":"expression-only","uid":"expression-only-uid"},"spec":{"selector":{"matchExpressions":[{"key":"app.kubernetes.io/name","operator":"Exists"}]}}},{"metadata":{"name":"tenant-a-kpa","uid":"deployment-uid"},"spec":{"selector":{"matchLabels":{"app.kubernetes.io/name":"renamed-kpa","app.kubernetes.io/instance":"tenant-a"}}}}]}'
                    return 0
                    ;;
                "get replicasets -n tenant-a -l app.kubernetes.io/name=renamed-kpa,app.kubernetes.io/instance=tenant-a -o json")
                    echo '{"items":[{"metadata":{"name":"tenant-a-kpa-rs","uid":"replicaset-uid","ownerReferences":[{"controller":true,"kind":"Deployment","name":"tenant-a-kpa","uid":"deployment-uid"}]}}]}'
                    return 0
                    ;;
                "get pods -n tenant-a -l app.kubernetes.io/name=renamed-kpa,app.kubernetes.io/instance=tenant-a -o json")
                    echo '{"items":[{"metadata":{"name":"tenant-a-kpa-0","ownerReferences":[{"controller":true,"kind":"ReplicaSet","name":"tenant-a-kpa-rs","uid":"replicaset-uid"}]}},{"metadata":{"name":"spoofed-pod","ownerReferences":[]}}]}'
                    return 0
                    ;;
                "get services -n tenant-a -l app.kubernetes.io/part-of=kedify-pod-autoscaler -o jsonpath={.items[*].metadata.name}")
                    echo 'tenant-a-kpa'
                    return 0
                    ;;
                "get pod -n tenant-a tenant-a-kpa-0 -o yaml")
                    echo 'kind: Pod'
                    return 0
                    ;;
                "describe pod -n tenant-a tenant-a-kpa-0")
                    echo 'KPA pod description'
                    return 0
                    ;;
                "logs -n tenant-a tenant-a-kpa-0"|"logs -n tenant-a tenant-a-kpa-0 --previous")
                    echo 'KPA controller log'
                    return 0
                    ;;
                "get --raw /api/v1/namespaces/tenant-a/services/http:tenant-a-kpa:metrics/proxy/metrics")
                    echo 'kpa_reconciliations_total 1'
                    return 0
                    ;;
            esac
            ;;
    esac

    return 1
}

function assert_contains() {
    local value="$1"
    local expected="$2"
    if [[ "$value" != *"$expected"* ]]; then
        echo "expected '$value' to contain '$expected'" >&2
        return 1
    fi
}

function test_debug_resolution() {
    local output=""

    MOCK_MODE="hpa"
    output=$(debug::__get_pod_autoscaler tenant-a keda-hpa-orders)
    assert_contains "$output" 'HorizontalPodAutoscaler'

    MOCK_MODE="kpa"
    output=$(debug::__get_pod_autoscaler tenant-a keda-hpa-orders)
    assert_contains "$output" 'KedifyPodAutoscaler'

    MOCK_MODE="conflict"
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders >/dev/null 2>&1; then
        echo 'conflicting HPA and KPA unexpectedly resolved without a selected class' >&2
        return 1
    fi
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders kpa >/dev/null 2>&1; then
        echo 'conflicting HPA and KPA unexpectedly resolved for explicit KPA class' >&2
        return 1
    fi
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders hpa >/dev/null 2>&1; then
        echo 'conflicting HPA and KPA unexpectedly resolved for explicit HPA class' >&2
        return 1
    fi

    MOCK_MODE="hpa"
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders kpa >/dev/null 2>&1; then
        echo 'explicit KPA selection unexpectedly fell back to HPA' >&2
        return 1
    fi

    MOCK_MODE="kpa"
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders hpa >/dev/null 2>&1; then
        echo 'explicit HPA selection unexpectedly fell back to KPA' >&2
        return 1
    fi

    MOCK_MODE="hpa_kpa_forbidden"
    output=$(debug::__get_pod_autoscaler tenant-a keda-hpa-orders 2>&1)
    assert_contains "$output" 'HorizontalPodAutoscaler'
    assert_contains "$output" 'same-named KPA conflict cannot be excluded'

    MOCK_MODE="absent"
    if debug::__get_pod_autoscaler tenant-a keda-hpa-orders >/dev/null 2>&1; then
        echo 'missing pod autoscaler unexpectedly resolved' >&2
        return 1
    fi

	MOCK_MODE="kpa_warning"
	output=$(debug::__get_pod_autoscaler tenant-a keda-hpa-orders 2>/dev/null)
	if ! echo "$output" | jq -e '.kind == "KedifyPodAutoscaler"' >/dev/null; then
		echo 'successful lookup warning contaminated the KPA JSON payload' >&2
		return 1
	fi
}

function test_kpa_status_metrics() {
    local so='{"metadata":{"name":"orders","namespace":"tenant-a","annotations":{"autoscaling.kedify.io/class":"kpa"}},"status":{"hpaName":"keda-hpa-orders"},"spec":{"triggers":[{"type":"cpu","metricType":"Utilization"},{"type":"memory","metricType":"AverageValue"},{"type":"rabbitmq","name":"queue","metricType":"AverageValue"}]}}'
    local output=""

    MOCK_MODE="kpa_status"
    output=$(debug::__scaledobject "$so" json false)
    assert_contains "$output" '"metric":"cpu","value":55'
    assert_contains "$output" '"metric":"memory","value":"128Mi"'
    assert_contains "$output" '"metric":"queue_depth","value":7'

	so='{"metadata":{"name":"orders","namespace":"tenant-a","annotations":{"autoscaling.kedify.io/class":"kpa"}},"status":{"hpaName":"keda-hpa-orders"},"spec":{"triggers":[{"type":"cpu"},{"type":"memory"}]}}'
	output=$(debug::__scaledobject "$so" json false)
	assert_contains "$output" '"metric":"cpu","value":55'
	assert_contains "$output" '"metric":"memory","value":"128Mi"'

	if [[ -n "$(debug::__resource_metric_value '{}' cpu Unsupported)" ]]; then
		echo 'unsupported resource metric type returned a value' >&2
		return 1
	fi
}

function test_dump_collection() {
    local temp_dir=""
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN

    QUIET_MODE="true"
    MOCK_MODE="dump"
    dump::__collect_kpa_crd "$temp_dir"
    dump::__collect_kpa_data tenant-a "$temp_dir"

    local expected_files=(
        kpa-crd.yaml
        kpa.yaml
        kpa-events.yaml
        kpa-controller-deployments.yaml
        kpa-services.yaml
        kpa-endpoints.yaml
        kpa-endpointslices.yaml
        kpa-tenant-a-kpa-0-pod.yaml
        kpa-tenant-a-kpa-0-pod.describe.txt
        kpa-tenant-a-kpa-0-logs.txt
        kpa-tenant-a-kpa-0-logs-previous.txt
        kpa-tenant-a-kpa-metrics.txt
    )
    local file=""
    for file in "${expected_files[@]}"; do
        if [[ ! -s "${temp_dir}/${file}" ]]; then
            echo "expected KPA diagnostic file '${file}'" >&2
            return 1
        fi
    done

    assert_contains "$(cat "${temp_dir}/kpa-tenant-a-kpa-metrics.txt")" 'kpa_reconciliations_total'
    if [[ -e "${temp_dir}/kpa-spoofed-pod-logs.txt" ]]; then
        echo 'selector-matching Pod without the KPA owner chain was collected' >&2
        return 1
    fi

    rm -rf "$temp_dir"
    trap - RETURN
}

function test_optional_absence() {
    local temp_dir=""
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN

    QUIET_MODE="true"
    MOCK_MODE="absent"
    dump::__collect_kpa_crd "$temp_dir"
    dump::__collect_kpa_data tenant-a "$temp_dir"

    if find "$temp_dir" -type f | grep -q .; then
        echo 'optional KPA absence created diagnostic files' >&2
        return 1
    fi

    rm -rf "$temp_dir"
    trap - RETURN
}

function test_kubectl_count_ignores_empty_list_messages() {
	MOCK_MODE="count_empty"
	if [[ "$(dump::__kubectl_count get pods -n empty)" -ne 0 ]]; then
		echo 'empty kubectl list message was counted as a resource' >&2
		return 1
	fi
}

function test_crlf_owner_chain() {
    local temp_dir=""
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN

    QUIET_MODE="true"
    MOCK_MODE="dump"
    REAL_JQ_BIN=$(type -P jq)
    function jq() {
        "$REAL_JQ_BIN" "$@" | sed -e 's/\r$//' -e 's/$/\r/'
    }

    dump::__collect_kpa_data tenant-a "$temp_dir"
    unset -f jq

    if [[ ! -s "${temp_dir}/kpa-tenant-a-kpa-0-pod.yaml" ]]; then
        echo 'CRLF owner-chain parsing did not discover the KPA Pod' >&2
        return 1
    fi
    if [[ -e "${temp_dir}/kpa-spoofed-pod-logs.txt" ]]; then
        echo 'CRLF owner-chain parsing collected the selector-spoofed Pod' >&2
        return 1
    fi

    rm -rf "$temp_dir"
    trap - RETURN
}

function main() {
    # shellcheck source=./debug.sh
    source "${SCRIPT_DIR}/debug.sh"
    # shellcheck source=./dump.sh
    source "${SCRIPT_DIR}/dump.sh"

    test_debug_resolution
    test_kpa_status_metrics
    test_dump_collection
    test_optional_absence
	test_kubectl_count_ignores_empty_list_messages
    test_crlf_owner_chain
    echo 'KPA diagnostics tests passed'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
