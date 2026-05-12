#!/usr/bin/env bash

function multicluster::__failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}

function multicluster::__configure_shell() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        emulate -L ksh
        setopt typeset_silent
    fi

    set -euo pipefail

    if [[ -n "${BASH_VERSION:-}" ]]; then
        set -E
        trap 'multicluster::__failure ${LINENO} "$BASH_COMMAND"' ERR
    fi
}


function multicluster::__print_usage() {
    cat <<EOF
Usage: multicluster <command> [options]
Commands:
  setup-member        Set up a member cluster
  list-members        List all configured member clusters
  delete-member       Delete a member cluster
  help                Show this help message
EOF
}

function multicluster::__print_usage_setup_member() {
    cat <<EOF
Usage: multicluster setup-member <member-name> --keda-kubeconfig <path> --member-kubeconfig <path> [--member-context <context>] [--keda-context <context>] [--namespace <namespace>]
Options:
  --keda-kubeconfig   Path to the KEDA cluster kubeconfig file (must have KEDA installed and sufficient RBAC to edit 'kedify-agent-multicluster-kubeconfigs' Secret)
  --member-kubeconfig Path to the member cluster kubeconfig file (must have sufficient RBAC to create Namespace, ServiceAccount, Role, RoleBinding and Secret)
  --keda-context      Context name for the KEDA cluster (optional)
  --member-context    Context name for the member cluster (optional)
  --member-api-url    API server URL for the member cluster (optional, default: derived from member kubeconfig)
  --namespace         Namespace where KEDA is deployed in the KEDA cluster (optional, default: keda)
  --dry-run           Print resources/patch payload instead of applying changes (optional)
  --yes               Automatically confirm prompts (optional)
EOF
}

function multicluster::__print_usage_list_members() {
    cat <<EOF
Usage: multicluster list-members [--namespace <namespace>] [--output <output>]
Options:
  --namespace         Namespace where KEDA is deployed in the KEDA cluster (optional, default: keda)
  --keda-context      Context name for the KEDA cluster (optional)
  --output, -o        Output format. Supported values: table, wide (optional, default: table)
EOF
}

function multicluster::__print_usage_delete_member() {
    cat <<EOF
Usage: multicluster delete-member <member-name> [--namespace <namespace>] [--yes]
Options:
  --namespace         Namespace where KEDA is deployed in the KEDA cluster (optional, default: keda)
  --keda-context      Context name for the KEDA cluster (optional)
  --yes               Automatically confirm prompts (optional)
EOF
}

function multicluster::__list_members() {
    local namespace="keda"
    local keda_context=""
    local output_format="table"

    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace|-n)
                namespace=$2
                shift 2
                ;;
            --keda-context)
                keda_context=$2
                shift 2
                ;;
            --output|-o)
                output_format=$2
                shift 2
                ;;
            *)
                echo "Unknown option: $1"
                multicluster::__print_usage_list_members
                exit 1
                ;;
        esac
    done

    if [[ "${output_format}" != "table" && "${output_format}" != "wide" ]]; then
        echo "Unknown output format: ${output_format}. Supported values: table, wide"
        exit 1
    fi

    if ! kubectl -n "${namespace}" --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs > /dev/null 2>&1; then
        echo "No member clusters are configured in KEDA cluster, secret 'kedify-agent-multicluster-kubeconfigs' not found."
        exit 1
    fi

    local members_list
    members_list=$(
        kubectl -n "${namespace}" --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs -o jsonpath="{.data}" |
            jq -r 'keys[] | sub("-cluster\\.kubeconfig$"; "")'
    )

    local multi_cluster_status="{}"
    local kedify_config_json
    if kedify_config_json=$(kubectl -n "${namespace}" --context="${keda_context}" get kedifyconfigurations -o json 2>/dev/null); then
        multi_cluster_status=$(echo "${kedify_config_json}" | jq -c '.items | map(select(.status.multiClusterStatus.clusters != null) | .status.multiClusterStatus.clusters) | first // {}')
    fi

    local member
    local state=""
    local info=""
    local cluster_width=7
    local state_width=5

    while IFS= read -r member; do
        [[ -z "${member}" ]] && continue

        state=$(echo "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].state // "Unknown"')

        if (( ${#member} > cluster_width )); then
            cluster_width=${#member}
        fi
        if (( ${#state} > state_width )); then
            state_width=${#state}
        fi
    done <<EOF
${members_list}
EOF

    if [[ "${output_format}" == "wide" ]]; then
        printf "%-${cluster_width}s  %-${state_width}s  %s\n" "CLUSTER" "STATE" "INFO"
    else
        printf "%-${cluster_width}s  %s\n" "CLUSTER" "STATE"
    fi

    while IFS= read -r member; do
        [[ -z "${member}" ]] && continue

        state=$(echo "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].state // "Unknown"')
        info=$(echo "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].info // "missing status information"')

        if [[ "${output_format}" == "wide" ]]; then
            printf "%-${cluster_width}s  %-${state_width}s  %s\n" "${member}" "${state}" "${info}"
        else
            printf "%-${cluster_width}s  %s\n" "${member}" "${state}"
        fi
    done <<EOF
${members_list}
EOF
}

function multicluster::__delete_member() {
    local member_name="$1"
    shift
    local namespace="keda"
    local auto_confirm="false"
    local keda_context=""

    if [[ -z "${member_name}" ]]; then
        echo "Member name is required for delete-member command."
        multicluster::__print_usage_delete_member
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace|-n)
                namespace=$2
                shift 2
                ;;
            --keda-context)
                keda_context=$2
                shift 2
                ;;
            --yes|-y)
                auto_confirm="true"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                multicluster::__print_usage_delete_member
                exit 1
                ;;
        esac
    done

    if ! kubectl -n "${namespace}" --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs > /dev/null 2>&1; then
        echo "No member clusters are configured in KEDA cluster, secret 'kedify-agent-multicluster-kubeconfigs' not found."
        exit 1
    fi
    if ! kubectl --context="${keda_context}" -n "${namespace}" get secret kedify-agent-multicluster-kubeconfigs -o json | jq -e --arg key "${member_name}-cluster.kubeconfig" '.data[$key]' > /dev/null; then
        echo "Member cluster '${member_name}' does not exist in KEDA cluster."
        exit 1
    fi
    if [[ "${auto_confirm}" != "true" ]]; then
        echo "Are you sure you want to delete member cluster '${member_name}'? (y/n)"
        read -r answer
        if [[ "${answer}" != "y" ]]; then
            echo "Aborting deletion of member cluster '${member_name}'."
            exit 1
        fi
    fi

    kubectl -n "${namespace}" patch secret kedify-agent-multicluster-kubeconfigs --type=json \
        -p="[{'op':'remove','path':'/data/${member_name}-cluster.kubeconfig'}]"

    echo "Member cluster '${member_name}' has been deleted successfully."
}

function multicluster::__setup_member() {
    local member_name=""
    local keda_kubeconfig=""
    local member_kubeconfig=""
    local keda_context=""
    local member_context=""
    local namespace="keda"
    local member_api_url=""
    local auto_confirm="false"
    local ca=""
    local server=""
    local selected_context=""
    local dry_run="false"
    local member_kubectl_context_args=()

    if [[ $# -eq 0 ]]; then
        echo "Member name is required for setup-member command."
        multicluster::__print_usage_setup_member
        exit 1
    fi
    member_name=$1
    shift
    if [[ -z "${member_name}" ]]; then
        echo "Member name is required for setup-member command."
        multicluster::__print_usage_setup_member
        exit 1
    fi
    if [[ ! "${member_name}" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo "Member name '${member_name}' contains invalid characters. Only alphanumeric characters, and hyphens are allowed."
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            --keda-kubeconfig)
                keda_kubeconfig=$2
                shift 2
                ;;
            --member-kubeconfig)
                member_kubeconfig=$2
                shift 2
                ;;
            --keda-context)
                keda_context=$2
                shift 2
                ;;
            --member-context)
                member_context=$2
                shift 2
                ;;
            --namespace|-n)
                namespace=$2
                shift 2
                ;;
            --member-api-url)
                member_api_url=$2
                shift 2
                ;;
            --yes|-y)
                auto_confirm="true"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                multicluster::__print_usage_setup_member
                exit 1
                ;;
        esac
    done

    if [[ -z $keda_kubeconfig || -z $member_kubeconfig ]]; then
        echo "Both --keda-kubeconfig and --member-kubeconfig are required."
        multicluster::__print_usage_setup_member
        exit 1
    fi

    export KUBECONFIG="${member_kubeconfig}"
    if [[ -n "${member_context}" ]]; then
        member_kubectl_context_args=(--context="${member_context}")
    fi
    if [[ "${dry_run}" == "true" ]]; then
        kubectl "${member_kubectl_context_args[@]}" create namespace "${namespace}" --dry-run=client -o yaml
        echo "---"
        kubectl "${member_kubectl_context_args[@]}" --namespace "${namespace}" create sa kedify-agent -n "${namespace}" --dry-run=client -o yaml
        echo "---"
        cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kedify-agent-token
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: kedify-agent
type: kubernetes.io/service-account-token
EOF
        echo "---"
        cat <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kedify-agent
rules:
- apiGroups: ["*"]
  resources: ["*/scale"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
        echo "---"
        kubectl "${member_kubectl_context_args[@]}" create clusterrolebinding kedify-agent --clusterrole=kedify-agent --serviceaccount="${namespace}":kedify-agent --dry-run=client -o yaml
        exit 0
    else
    kubectl "${member_kubectl_context_args[@]}" create namespace "${namespace}" --dry-run=client -o yaml | kubectl "${member_kubectl_context_args[@]}" apply -f -
    kubectl "${member_kubectl_context_args[@]}" --namespace "${namespace}" create sa kedify-agent -n "${namespace}" --dry-run=client -o yaml | kubectl "${member_kubectl_context_args[@]}" apply -f -
    kubectl "${member_kubectl_context_args[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kedify-agent-token
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: kedify-agent
type: kubernetes.io/service-account-token
EOF

    kubectl "${member_kubectl_context_args[@]}" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kedify-agent
rules:
- apiGroups: ["*"]
  resources: ["*/scale"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
    kubectl "${member_kubectl_context_args[@]}" create clusterrolebinding kedify-agent --clusterrole=kedify-agent --serviceaccount="${namespace}":kedify-agent --dry-run=client -o yaml | kubectl "${member_kubectl_context_args[@]}" apply -f -
    fi
    # Retrieve the CA certificate and token from the member cluster
    if ! ca=$(kubectl "${member_kubectl_context_args[@]}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['ca\.crt']}" 2>/dev/null); then
        ca=""
    fi
    if [[ -z "$ca" ]]; then
        if [[ "${dry_run}" == "true" ]]; then
            exit 0
        fi
        echo "Failed to retrieve CA certificate from member cluster. Ensure that the ServiceAccount and Secret are set up correctly."
        exit 1
    fi
    # Wait for the token to be populated in the secret
    local retries=5
    local wait_time=2
    local token=""
    local raw=""

    for ((attempt=1; attempt<=retries; attempt++)); do
        if raw=$(kubectl "${member_kubectl_context_args[@]}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['token']}" | base64 --decode); then
            if [[ -n "$raw" ]]; then
                token="$raw"
                break
            fi
        else
            :
        fi
        if (( attempt < retries )); then
            echo "Token not yet available in member cluster secret, retrying in $wait_time seconds... (Attempt: $attempt/$retries)"
            sleep $wait_time
        fi
    done
    if [[ -z "$token" ]]; then
        if [[ "${dry_run}" == "true" ]]; then
            exit 0
        fi
        echo "Failed to retrieve token from member cluster after $retries attempts. Ensure that the ServiceAccount and Secret are set up correctly."
        exit 1
    fi
    if [[ -n "$member_api_url" ]]; then
        server="${member_api_url}"
    else
        if [[ -n "$member_context" ]]; then
            server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${member_context}')].cluster.server}")
            if [[ -z "$server" ]]; then
                echo "Context '${member_context}' not found in member kubeconfig ${member_kubeconfig}"
                exit 1
            fi
        else
            selected_context=$(kubectl config current-context)
            if [[ -z "$selected_context" ]]; then
                echo "No current context set in member kubeconfig ${member_kubeconfig}, please specify --member-context"
                exit 1
            fi
            server=$(kubectl config view -o jsonpath="{.clusters[?(@.name=='${selected_context}')].cluster.server}")
        fi
    fi
    # Create a secure temporary kubeconfig file
    local temp_kubeconfig=""
    local temp_kubeconfig_escaped=""
    temp_kubeconfig=$(mktemp /tmp/kedify-agent-"${member_name}"-kubeconfig.XXXXXX)
    chmod 600 "$temp_kubeconfig"
    temp_kubeconfig_escaped=$(printf '%q' "$temp_kubeconfig")
    trap 'rm -f -- '"${temp_kubeconfig_escaped}" EXIT

    # Create kubeconfig for the member cluster to be used by kedify-agent in KEDA cluster
    cat <<EOF > "$temp_kubeconfig"
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${ca}
    server: ${server}
  name: ${member_name}-cluster
contexts:
- context:
    cluster: ${member_name}-cluster
    user: kedify-agent
  name: kedify-agent@${member_name}
current-context: kedify-agent@${member_name}
users:
- name: kedify-agent
  user:
    token: ${token}
EOF

    export KUBECONFIG="${keda_kubeconfig}"
    if [[ "$auto_confirm" != "true" ]]; then
        if kubectl -n "${namespace}" --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs -o json | jq -e --arg key "${member_name}-cluster.kubeconfig" '.data[$key]' > /dev/null; then
            echo "Member cluster '${member_name}' is already set up in KEDA cluster. Replace? (y/n)"
            read -r answer
            if [[ "${answer}" != "y" ]]; then
                echo "Aborting setup for member cluster '${member_name}'."
                exit 1
            fi
        fi
    fi
    kubectl -n "${namespace}" --context="${keda_context}" patch secret kedify-agent-multicluster-kubeconfigs \
        --type=merge \
        -p "$(kubectl create secret generic temp \
        --from-file="${member_name}"-cluster.kubeconfig="${temp_kubeconfig}" \
        --dry-run=client -o json | jq '{data:.data}')"

    echo "Member cluster '${member_name}' has been set up successfully."
}

function multicluster::__cmd_impl() {
    if [[ $# -eq 0 ]]; then
        multicluster::__print_usage
        exit 1
    fi
    local cmd=$1
    shift
    case $cmd in
        setup-member)
            multicluster::__setup_member "$@"
            ;;
        list-members)
            multicluster::__list_members "$@"
            ;;
        delete-member)
            if [[ $# -eq 0 ]]; then
                echo "Member name is required for delete-member command."
                multicluster::__print_usage
                exit 1
            fi
            local member_name=$1
            shift
            multicluster::__delete_member "${member_name}" "$@"
            ;;
        help)
            multicluster::__print_usage
            ;;
        *)
            echo "Unknown command: $cmd"
            multicluster::__print_usage
            exit 1
            ;;
    esac
}

function multicluster::cmd() (
    multicluster::__configure_shell
    multicluster::__cmd_impl "$@"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    multicluster::cmd "$@"
fi
