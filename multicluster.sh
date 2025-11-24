#!/usr/bin/env bash

set -euo pipefail
set -Eo functrace

function multicluster::__failure() {
    local lineno=$1
    local msg=$2
    echo "Failed at $lineno: $msg"
}
trap 'multicluster::__failure ${LINENO} "$BASH_COMMAND"' ERR


function multicluster::__print_usage() {
    cat <<EOF
Usage: multicluster <command> [options]
Commands:
  setup-member        Set up a member cluster
  help                Show this help message
EOF
}

function multicluster::__setup_member_print_usage() {
    cat <<EOF
Usage: multicluster setup-member <member-name> --keda-kubeconfig <path> --member-kubeconfig <path> [--member-context <context>] [--keda-context <context>] [--namespace <namespace>]
Options:
  --keda-kubeconfig   Path to the KEDA cluster kubeconfig file (must have KEDA installed and sufficient RBAC to edit 'kedify-agent-multicluster-kubeconfigs' Secret)
  --member-kubeconfig Path to the member cluster kubeconfig file (must have sufficient RBAC to create Namespace, ServiceAccount, Role, RoleBinding and Secret)
  --keda-context      Context name for the KEDA cluster (optional)
  --member-context    Context name for the member cluster (optional)
  --member-api-url    API server URL for the member cluster (optional, default: derived from member kubeconfig)
  --namespace         Namespace where KEDA is deployed KEDA cluster (optional, default: keda)
  --yes               Automatically confirm prompts (optional)
EOF
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

    member_name=$1
    shift

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
            --namespace)
                namespace=$2
                shift 2
                ;;
            --member-api-url)
                member_api_url=$2
                shift 2
                ;;
            --yes)
                auto_confirm="true"
                shift
                ;;
            *)
                echo "Unknown option: $1"
                multicluster::__setup_member_print_usage
                exit 1
                ;;
        esac
    done

    if [[ -z $keda_kubeconfig || -z $member_kubeconfig ]]; then
        echo "Both --keda-kubeconfig and --member-kubeconfig are required."
        multicluster::__setup_member_print_usage
        exit 1
    fi

    export KUBECONFIG="${member_kubeconfig}"
    kubectl --context="${member_context}" create namespace "${namespace}" --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
    kubectl --context="${member_context}" --namespace "${namespace}" create sa kedify-agent -n keda --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
    kubectl --context="${member_context}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: kedify-agent-token
  namespace: ${namespace}
  annotations:
    kubernetes.io/service-account.name: kedify-agent
type: kubernetes.io/service-account-token
EOF

    kubectl --context="${member_context}" apply -f - <<EOF
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
EOF
    kubectl --context="${member_context}" create clusterrolebinding kedify-agent --clusterrole=kedify-agent --serviceaccount="${namespace}":kedify-agent --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
    kubectl --context="${member_context}" patch sa kedify-agent -n keda -p '{"secrets":[{"name":"kedify-agent-token"}]}'

    # create kubeconfig for the member cluster to be used by kedify-agent in KEDA cluster
    ca=$(kubectl --context="${member_context}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['ca\.crt']}")
    if [[ -z "$ca" ]]; then
        echo "Failed to retrieve CA certificate from member cluster. Ensure that the ServiceAccount and Secret are set up correctly."
        exit 1
    fi
    token=$(kubectl --context="${member_context}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['token']}" | base64 --decode)
    if [[ -z "$token" ]]; then
        echo "Failed to retrieve token from member cluster. Ensure that the ServiceAccount and Secret are set up correctly."
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
    cat <<EOF > /tmp/kedify-agent-${member_name}-kubeconfig
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

    # add the kubeconfig to the secret that already exists in the keda cluster
    KUBECONFIG="${keda_kubeconfig}"

    exists_key=$(kubectl -n ${namespace} --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs -o jsonpath="{.data['${member_name}-cluster\.kubeconfig']}" || echo "")
    if [[ -n "${exists_key}" && "${auto_confirm}" != "true" ]]; then
        echo "Member cluster '${member_name}' is already set up in KEDA cluster. Replace? (y/n)"
        read -r answer
        if [[ "${answer}" != "y" ]]; then
            echo "Aborting setup for member cluster '${member_name}'."
            exit 1
        fi
    fi
    kubectl -n ${namespace} --context="${keda_context}" patch secret kedify-agent-multicluster-kubeconfigs \
        --type=merge \
        -p "$(kubectl create secret generic temp \
        --from-file=${member_name}-cluster.kubeconfig=/tmp/kedify-agent-${member_name}-kubeconfig \
        --dry-run=client -o json | jq '{data:.data}')"

    echo "Member cluster '${member_name}' has been set up successfully."
}

function multicluster::cmd() {
    if [[ $# -eq 0 ]]; then
        multicluster::__print_usage
        exit 1
    fi
    local cmd=$1
    if [[ $cmd == "setup-member" ]]; then
        shift
        multicluster::__setup_member "$@"
    elif [[ $cmd == "help" ]]; then
        multicluster::__print_usage
        exit 0
    else
        echo "Unknown command: $cmd"
        multicluster::__print_usage
        exit 1
    fi
}
