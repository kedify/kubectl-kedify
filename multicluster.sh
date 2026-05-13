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
Usage: multicluster delete-member <member-name> [--namespace <namespace>] [--keda-context <context>] [--provider <file|kubeconfig>] [--yes]
Options:
  --namespace         Namespace where KEDA is deployed in the KEDA cluster (optional, default: keda)
  --keda-context      Context name for the KEDA cluster (optional)
  --provider          Which provider's entry to delete (optional). Required only when the member is registered through both providers (collision). Values: file, kubeconfig.
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

    # Source the inventory from KedifyConfiguration's multiClusterStatus —
    # the agent merges file-mounted and Secret-registered providers there, so
    # this is the only view that covers both registration paths.
    # Use printf '%s' rather than echo when piping to jq: bash's `echo` can
    # interpret embedded backslash sequences (e.g. \n inside a JSON-escaped
    # annotation value) which mangles the payload before jq sees it.
    # Let kubectl errors (CRD missing, RBAC denied, bad context, etc.) print
    # naturally to stderr — falling back to empty would mask real failures
    # as "no members configured".
    local multi_cluster_status="{}"
    local kedify_config_json
    if ! kedify_config_json=$(kubectl -n "${namespace}" --context="${keda_context}" get kedifyconfigurations -o json); then
        echo "Failed to read KedifyConfiguration resources from the KEDA cluster." >&2
        exit 1
    fi
    multi_cluster_status=$(printf '%s' "${kedify_config_json}" | jq -c '.items | map(select(.status.multiClusterStatus.clusters != null) | .status.multiClusterStatus.clusters) | first // {}')

    local members_list
    members_list=$(printf '%s' "${multi_cluster_status}" | jq -r 'keys[]?' | sort)
    if [[ -z "${members_list}" ]]; then
        echo "No member clusters are configured in the KEDA cluster."
        exit 1
    fi

    local member
    local state=""
    local provider=""
    local info=""
    local cluster_width=7
    local state_width=5
    local provider_width=8

    while IFS= read -r member; do
        [[ -z "${member}" ]] && continue

        state=$(printf '%s' "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].state // "Unknown"')
        provider=$(printf '%s' "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].provider // "unknown"')

        if (( ${#member} > cluster_width )); then
            cluster_width=${#member}
        fi
        if (( ${#state} > state_width )); then
            state_width=${#state}
        fi
        if (( ${#provider} > provider_width )); then
            provider_width=${#provider}
        fi
    done <<EOF
${members_list}
EOF

    if [[ "${output_format}" == "wide" ]]; then
        printf "%-${cluster_width}s  %-${state_width}s  %-${provider_width}s  %s\n" "CLUSTER" "STATE" "PROVIDER" "INFO"
    else
        printf "%-${cluster_width}s  %s\n" "CLUSTER" "STATE"
    fi

    while IFS= read -r member; do
        [[ -z "${member}" ]] && continue

        state=$(printf '%s' "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].state // "Unknown"')
        provider=$(printf '%s' "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].provider // "unknown"')
        info=$(printf '%s' "${multi_cluster_status}" | jq -r --arg member "${member}" '.[$member].info // "missing status information"')

        if [[ "${output_format}" == "wide" ]]; then
            printf "%-${cluster_width}s  %-${state_width}s  %-${provider_width}s  %s\n" "${member}" "${state}" "${provider}" "${info}"
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
    local provider_flag=""

    if [[ -z "${member_name}" ]]; then
        echo "Member name is required for delete-member command."
        multicluster::__print_usage_delete_member
        exit 1
    fi
    # Same constraint setup-member enforces. Guards both the Secret name path
    # and the JSON Pointer used in the bundled-Secret patch (where `/` and `~`
    # have special meaning).
    if [[ ! "${member_name}" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo "Member name '${member_name}' contains invalid characters. Only lowercase alphanumeric characters and hyphens are allowed, starting with a letter."
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
            --provider)
                if [[ -z "${2:-}" || "${2:0:1}" == "-" ]]; then
                    echo "--provider requires a value (file or kubeconfig)."
                    multicluster::__print_usage_delete_member
                    exit 1
                fi
                provider_flag=$2
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

    if [[ -n "${provider_flag}" && "${provider_flag}" != "file" && "${provider_flag}" != "kubeconfig" ]]; then
        echo "Invalid --provider value '${provider_flag}'. Supported: file, kubeconfig."
        exit 1
    fi

    # A member can be registered through either the file provider (an entry in
    # the bundled `kedify-agent-multicluster-kubeconfigs` Secret) or the
    # kubeconfig provider (a per-cluster Secret named after the member, labeled
    # `sigs.k8s.io/multicluster-runtime-kubeconfig=true`). Detect both before
    # deciding what to remove. Same member name can be registered through both
    # at once (cross-provider collision); in that case the operator must
    # disambiguate with --provider.
    #
    # `--ignore-not-found=true` is the discriminator we want: kubectl exits 0
    # with empty stdout only when the resource genuinely does not exist; real
    # errors (RBAC denied, API unreachable, bad context, etc.) still surface
    # on stderr and exit non-zero rather than masquerading as "not registered".
    local in_bundled="false"
    local in_labeled="false"
    local bundled_data_key="${member_name}-cluster.kubeconfig"

    local bundled_json
    if ! bundled_json=$(kubectl -n "${namespace}" --context="${keda_context}" get secret kedify-agent-multicluster-kubeconfigs --ignore-not-found=true -o json); then
        echo "Failed to read Secret 'kedify-agent-multicluster-kubeconfigs' from the KEDA cluster." >&2
        exit 1
    fi
    # Null-safe access in case the Secret exists but has an empty/absent .data
    # (happens after the last member entry is removed).
    if [[ -n "${bundled_json}" ]] && printf '%s' "${bundled_json}" | jq -e --arg key "${bundled_data_key}" '(.data // {})[$key] != null' > /dev/null; then
        in_bundled="true"
    fi

    local labeled_json
    if ! labeled_json=$(kubectl -n "${namespace}" --context="${keda_context}" get secret "${member_name}" --ignore-not-found=true -o json); then
        echo "Failed to read Secret '${member_name}' from the KEDA cluster." >&2
        exit 1
    fi
    if [[ -n "${labeled_json}" ]] && printf '%s' "${labeled_json}" | jq -e '.metadata.labels["sigs.k8s.io/multicluster-runtime-kubeconfig"] == "true"' > /dev/null; then
        in_labeled="true"
    fi

    if [[ "${in_bundled}" == "false" && "${in_labeled}" == "false" ]]; then
        echo "Member cluster '${member_name}' is not registered in KEDA cluster (checked bundled Secret 'kedify-agent-multicluster-kubeconfigs' and labeled Secret '${member_name}')."
        exit 1
    fi

    if [[ "${in_bundled}" == "true" && "${in_labeled}" == "true" && -z "${provider_flag}" ]]; then
        echo "Member cluster '${member_name}' is registered through both providers:"
        echo "  - bundled Secret 'kedify-agent-multicluster-kubeconfigs' (file provider)"
        echo "  - labeled Secret '${member_name}' (kubeconfig provider)"
        echo "Specify which one to delete with --provider <file|kubeconfig>."
        exit 1
    fi

    if [[ "${provider_flag}" == "file" && "${in_bundled}" == "false" ]]; then
        echo "Member cluster '${member_name}' is not registered through the file provider (no entry in bundled Secret 'kedify-agent-multicluster-kubeconfigs')."
        exit 1
    fi
    if [[ "${provider_flag}" == "kubeconfig" && "${in_labeled}" == "false" ]]; then
        echo "Member cluster '${member_name}' is not registered through the kubeconfig provider (no labeled Secret '${member_name}')."
        exit 1
    fi

    local delete_bundled="false"
    local delete_labeled="false"
    case "${provider_flag}" in
        file)
            delete_bundled="true"
            ;;
        kubeconfig)
            delete_labeled="true"
            ;;
        *)
            # No flag and no collision: delete whichever single provider has it.
            delete_bundled="${in_bundled}"
            delete_labeled="${in_labeled}"
            ;;
    esac

    if [[ "${delete_bundled}" == "true" ]]; then
        echo "Member cluster '${member_name}' will be removed from bundled Secret 'kedify-agent-multicluster-kubeconfigs' (file provider)."
    fi
    if [[ "${delete_labeled}" == "true" ]]; then
        echo "Member cluster '${member_name}' will be removed by deleting labeled Secret '${member_name}' (kubeconfig provider)."
    fi
    if [[ "${auto_confirm}" != "true" ]]; then
        echo "Continue? (y/n)"
        read -r answer
        if [[ "${answer}" != "y" ]]; then
            echo "Aborting deletion of member cluster '${member_name}'."
            exit 1
        fi
    fi

    if [[ "${delete_bundled}" == "true" ]]; then
        # JSON Patch payload must be valid JSON (double-quoted keys/values).
        # member_name is validated against the DNS-label regex above, so it
        # contains no JSON Pointer special characters (`/`, `~`).
        local patch_json
        patch_json=$(printf '[{"op":"remove","path":"/data/%s"}]' "${bundled_data_key}")
        kubectl -n "${namespace}" --context="${keda_context}" patch secret kedify-agent-multicluster-kubeconfigs --type=json -p "${patch_json}"
    fi
    if [[ "${delete_labeled}" == "true" ]]; then
        kubectl -n "${namespace}" --context="${keda_context}" delete secret "${member_name}"
    fi

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
    kubectl --context="${member_context}" create namespace "${namespace}" --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
    kubectl --context="${member_context}" --namespace "${namespace}" create sa kedify-agent -n "${namespace}" --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
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
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["batch"]
  resources: ["jobs"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
EOF
    kubectl --context="${member_context}" create clusterrolebinding kedify-agent --clusterrole=kedify-agent --serviceaccount="${namespace}":kedify-agent --dry-run=client -o yaml | kubectl --context="${member_context}" apply -f -
    # Retrieve the CA certificate and token from the member cluster
    ca=$(kubectl --context="${member_context}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['ca\.crt']}")
    if [[ -z "$ca" ]]; then
        echo "Failed to retrieve CA certificate from member cluster. Ensure that the ServiceAccount and Secret are set up correctly."
        exit 1
    fi
    # Wait for the token to be populated in the secret
    local retries=5
    local wait_time=2
    local token=""
    local raw=""

    for ((attempt=1; attempt<=retries; attempt++)); do
        if raw=$(kubectl --context="${member_context}" get secret kedify-agent-token -n "${namespace}" -o jsonpath="{.data['token']}" | base64 --decode); then
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
