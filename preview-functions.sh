#!/bin/bash
export COL="\e[2;35;49m"
export RES="\e[0m"

preview_ing() {
    [[ $# -lt 2 ]] && echo "usage: $0 <namespace  name> <kind>" && exit 1
    export COL="\e[1;31m"
    export AUTOSCALABLE_RESOURCE=$(echo ${1} | awk '{ print $2}')
    export NS=$(echo ${1} | awk '{ print $1}')

    export HSO_NAME=${AUTOSCALABLE_RESOURCE}
    export HSO_HOST=$(kubectl get -n${NS} ${2} ${AUTOSCALABLE_RESOURCE} -ojson | jq -r '.spec.rules[0].host')
    export HSO_SVC=$(kubectl get -n${NS} ${2} ${AUTOSCALABLE_RESOURCE} -ojson | jq -r '.spec.rules[0].http.paths[0].backend.service.name')
    export HSO_PORT=$(kubectl get -n${NS} ${2} ${AUTOSCALABLE_RESOURCE} -ojson | jq -r '.spec.rules[0].http.paths[0].backend.service.port.number')
    printf "\n${COL}%18s:${RES} '%s'\n" "Namespace" "${NS}"
    printf "${COL}%18s:${RES} '%s'\n" "${2}" "${AUTOSCALABLE_RESOURCE}"
    printf "${COL}%18s:${RES} '%s'\n" "Discovered host" "${HSO_HOST}"
    printf "${COL}%18s:${RES} '%s'\n" "Discovered service" "${HSO_SVC}"
    printf "${COL}%18s:${RES} '%s'\n" "Discovered port" "${HSO_PORT}"
    echo -e "\n\nFull yaml:\n----------"
    kubectl get -n${NS} ${2} ${AUTOSCALABLE_RESOURCE} -oyaml | bat --color=always -lyaml --file-name="kubectl get -n${NS} ${2} ${AUTOSCALABLE_RESOURCE}"
}
