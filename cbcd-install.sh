#!/bin/sh

# Copyright (c) 2022 CloudBees, Inc.
# All rights reserved.

set -e

K8S_NAMESPACE="dev"

#DOCKER_REGISTRY="docker.io/cloudbees"
#DOCKER_TAG="10.5.1.154796_3.2.14_20220523"
#DOCKER_TAG=latest

#DOCKER_REGISTRY="gcr.io/cloudbees-ops-gcr/cd"
#DOCKER_TAG="build-10.6.0.155127_3.2.14_20220607"
#DOCKER_TAG=latest

DOCKER_REGISTRY="gcr.io/flow-testing-project/bee-19305"
DOCKER_TAG=build

HELM_RELEASE="cbcd"
HELM_CHART="cloudbees/cloudbees-flow"
HELM_ARGS=""

CBCD_DEMO_MODE=0

# -----------------------------------------------------------

DEBUG=1

# -----------------------------------------------------------

log() {
    (set -x; "$@")
}

install() {

    local ENV_PARAMS
    local HELM_STATUS
    local CMD

    updateHelmRepo

    rm -f flow-server-init-job.log
    rm -f cluster-events.log

    msg "Create namespace ..."
    if [ -z "$(log kubectl get namespace "$K8S_NAMESPACE" --ignore-not-found)" ]; then
        log kubectl create namespace "$K8S_NAMESPACE"
    fi

    checkDockerLatestTag
    checkDockerRegistryAccess

    msg "Get env parameters ..."
    ENV_PARAMS="$(log "$(dirname "$0")"/gke-env.sh -silent info)"

    msg "Install ..."
    log kubectl delete --namespace "$K8S_NAMESPACE" job.batch/flow-server-init-job || true
    # echo removes \n
    CMD="$(echo helm upgrade \"$HELM_RELEASE\" \"$HELM_CHART\" --install --namespace \"$K8S_NAMESPACE\" --create-namespace \
        --timeout 30m \
        --set images.registry=$DOCKER_REGISTRY --set images.tag=$DOCKER_TAG \
        --set zookeeper.image.repository=$DOCKER_REGISTRY/cbflow-tools --set zookeeper.image.tag=$DOCKER_TAG \
        $ENV_PARAMS \
        $HELM_ARGS \
        "$@")"
    msg "$CMD"
    # eval allows quotes in the variable
    eval $CMD &
    HELM_PID=$!

    # wait until the release starts
    while true; do

        checkHelmAlive
        checkEventsAlive

        if HELM_STATUS="$(helm status "$HELM_RELEASE" --namespace "$K8S_NAMESPACE" 2>/dev/null | grep '^STATUS:' | awk '{print $2}')"; then
            #msg debug "The helm release in state: '$HELM_STATUS'"
            # we accept only "PENDING_INSTALL" status here
            if [ "$HELM_STATUS" = "PENDING_INSTALL" ] || [ "$HELM_STATUS" = "pending-install" ] || [ "$HELM_STATUS" = "pending-upgrade" ]; then
                msg stage "The helm release \"$HELM_RELEASE\" in state: $HELM_STATUS"
                break
            fi
        fi

        sleep 1

    done

    CLUSTER_STATE_ON_ERROR=1
    waitForJob "flow-server-init-job" 300
    CLUSTER_STATE_ON_ERROR=0

    kubectl logs pod/"$JOB_POD" --namespace "$K8S_NAMESPACE" --follow | tee flow-server-init-job.log | while IFS= read -r line; do

        if echo "$line" | grep -q '^[0-9:T\.-]\+ \* '; then

            # strip timestamp
            line="${line#* }"

            case "$line" in
                '* Cluster successfully initialized')
                    msg stage "$line"
                    ;;
                '* ERROR:'*)
                    msg error "*${line#*:}"
                    ;;
                '* WARNING:'*)
                    msg warning "*${line#*:}"
                    ;;
                *)
                    msg info "$line"
                    ;;
            esac

            continue

        fi

         case "$line" in
            *' | Launching a JVM...'*)
                msg stage "CloudBees Flow server process started"
                ;;
            *' | ERROR | '*)
                msg error "${line##* | }"
                ;;
            *' | WARN  | '*)
                # Filter out some unnecessary warning messages
                case "$line" in
                    *'MySQL does not support a timestamp precision of'*)
                        continue
                        ;;
                    *' | Invalid session in message'*)
                        continue
                        ;;
                esac
                msg warning "${line##* | }"
                ;;
            *' - Shutdown initiated...'|*' - Shutdown completed.'|*' - Starting...'|*' - Start completed.')
                msg info "${line##* | }"
                ;;
            *' | Connected to the database')
                msg info "${line##* | }"
                ;;
            *' | Attempting upgrade from database version '*)
                msg stage "${line##* | }"
                ;;
            *' | Upgrade script '*)
                msg info "${line##* | }"
                ;;
            *' | Executing setup script '*)
                msg stage "${line##* | }"
                ;;
            *' | Setup script '*)
                msg info "${line##* | }"
                ;;
            *' | Installing plugin '*)
                msg info "${line##* | }"
                ;;
            *' | commanderServer is running')
                msg stage "${line##* | }"
                if [ "$DEMO_MODE" = 1 ]; then
                    break
                fi
                ;;
            *' | Stopping all services')
                msg stage "${line##* | }"
                ;;
            *' | Shutdown is complete')
                msg stage "${line##* | }"
                ;;
        esac

    done

    wait $HELM_PID
    unset HELM_PID
    exit $?

}

uninstall() {
    msg "Uninstall ..."
    log kubectl delete --namespace "$K8S_NAMESPACE" job.batch/flow-server-init-job || true
    log helm uninstall "$HELM_RELEASE" --namespace "$K8S_NAMESPACE" --wait --debug
    # remove PVCs also by removing whole namespace
    # https://github.com/helm/helm/issues/5156
    log kubectl delete namespace "$K8S_NAMESPACE" --wait=true
}

info() {

    msg "Get cluster info ..."

    #local LB_HOST_NAME="$(log kubectl get service $HELM_RELEASE-nginx-ingress-controller --namespace "$K8S_NAMESPACE" -o jsonpath="{.status.loadBalancer.ingress[0].hostname}")"
    local LB_HOST_IP="$(log kubectl get service $HELM_RELEASE-nginx-ingress-controller --namespace "$K8S_NAMESPACE" -o jsonpath="{.status.loadBalancer.ingress[0].ip}")"
    local ADMIN_PASS="$(log kubectl get secret --namespace "$K8S_NAMESPACE" $HELM_RELEASE-cloudbees-flow-credentials -o jsonpath="{.data.CBF_SERVER_ADMIN_PASSWORD}" | base64 --decode)"

    msg "CBCD UI is available at: https://${LB_HOST_IP}/flow"
    msg "Username: admin"
    msg "Password: $ADMIN_PASS"
    msg "CBCD server is available at: https://${LB_HOST_IP}:8443"

}

# -----------------------------------------------------------

msg() {
    local MSG_PREFIX=""
    local MSG
    case "$1" in
        stage)
            MSG_PREFIX="$_C_gray[${_C_green}STAGE$_C_gray]$_C "
            shift
            ;;
        critical)
            MSG_PREFIX="$_C_gray[${_C_RED}CRIT $_C_gray]$_C "
            shift
            ;;
        error)
            MSG_PREFIX="$_C_gray[${_C_red}ERROR$_C_gray]$_C "
            shift
            ;;
        warning)
            MSG_PREFIX="$_C_gray[${_C_yellow}WARN $_C_gray]$_C "
            shift
            ;;
        debug)
            [ "$DEBUG" = "1" ] || return 0
            MSG_PREFIX="$_C_gray[${_C_GRAY}DEBUG$_C_gray]$_C "
            shift
            ;;
        info)
            MSG_PREFIX="$_C_gray[${_C_blue}INFO $_C_gray]$_C "
            shift
            ;;
        *)
            MSG_PREFIX="$_C_gray[${_C_blue}INFO $_C_gray]$_C "
            ;;
    esac
    MSG="$(echo "$1" | sed -e "s/\"\\([^\"]*\\)\"/$_C_gray\"$_C$_BOLD\1$_C$_C_gray\"$_C/g")"
    echo "$(date --iso-8601=seconds) $MSG_PREFIX$MSG"
}

initColors() {
    if [ "$(tty)" != "not a tty" ]; then
        _C_WHITE="$(printf '\033[1;37m')"
        _C_gray="$(printf '\033[1;30m')"
        _C_GRAY="$(printf '\033[0;37m')"
        _C_red="$(printf '\033[0;31m')"
        _C_RED="$(printf '\033[1;31m')"
        _C_green="$(printf '\033[0;32m')"
        _C_GREEN="$(printf '\033[1;32m')"
        _C_yellow="$(printf '\033[0;33m')"
        _C_YELLOW="$(printf '\033[1;33m')"
        _C_blue="$(printf '\033[0;34m')"
        _C_BLUE="$(printf '\033[1;34m')"
        _C_purple="$(printf '\033[0;35m')"
        _C_PURPLE="$(printf '\033[1;35m')"
        _C_cyan="$(printf '\033[0;36m')"
        _C_CYAN="$(printf '\033[1;36m')"
        _C="$(printf '\033[0m')"
        _C_BOLD="$(printf '\033[1m')"
    fi
}

exitWithError() {

    local POD_READY
    local POD_STATUS
    local POD_NAME
    local MORE_PODS

    [ -n "$1" ] && msg critical "$1"

    if [ "$CLUSTER_STATE_ON_ERROR" = "1" ]; then
        kubectl get pods --namespace "$K8S_NAMESPACE" | tail -n +2 | while IFS= read -r line; do
            # msg debug "pod: $line"
            POD_READY="$(echo "$line" | awk '{print $2}')"
            POD_STATUS="$(echo "$line" | awk '{print $3}')"
            [ "$POD_STATUS" = "Completed" ] && continue
            [ "${POD_READY%%/*}" != "0" ] && [ "$POD_STATUS" = "Running" ] && continue
            POD_NAME="$(echo "$line" | awk '{print $1}')"
            if [ -z "$MORE_PODS" ]; then
                echo
                msg error "The following pods are not running or not ready:"
                MORE_PODS=1
            fi
            echo
            msg error "Pod name: \"$POD_NAME\"; Ready: $POD_READY; Status: $POD_STATUS; Events:"
            kubectl get event --namespace "$K8S_NAMESPACE" --field-selector involvedObject.name="$POD_NAME" --sort-by='.metadata.creationTimestamp'
        done
    fi

    #set +e
    #log kubectl delete --namespace "$K8S_NAMESPACE" job.batch/flow-server-init-job
    #log kubectl delete --namespace "$K8S_NAMESPACE" job.batch/flow-post-init
    #log helm del --purge cloudbees-flow
    #set -e
    exit 1

}

waitForJob() {

    local JOB_NAME="$1"
    local TIMEOUT="$2"
    local START_TIME="$(date "+%s")"
    local JOB_DESCRIPTION
    local STATUS
    local COUNT

    unset JOB_POD

    msg "Waiting for the \"$JOB_NAME\" to be available..."

    while true; do

        checkHelmAlive

        if [ -z "$DEMO_MODE" ]; then
            set +e
            if POD_DESCRIPTION="$(kubectl get pods --selector app=flow-server --namespace dev --output jsonpath='{.items[0].spec.containers[0].env[*].name}' 2>/dev/null)"; then
                if echo "$POD_DESCRIPTION" | grep --silent --fixed-strings 'CBF_ZK_CONNECTION'; then
                    DEMO_MODE=0
                    msg "Clustered deployment detected"
                else
                    DEMO_MODE=1
                    msg "NON-clustered deployment detected"
                fi
            fi
        fi

        if [ -z "$JOB_POD" ]; then
            if [ "$DEMO_MODE" = 1 ]; then
                if POD_DESCRIPTION="$(kubectl get pods --selector app=flow-server --namespace "$K8S_NAMESPACE" 2>/dev/null)"; then
                    JOB_POD="$(echo "$POD_DESCRIPTION" | tail -1 | awk '{print $1}')"
                    if [ -n "$JOB_POD" ]; then
                        msg stage "Flow server is running on pod: '$JOB_POD'"
                    fi
                fi
            else
                if JOB_DESCRIPTION="$(kubectl describe job.batch/$JOB_NAME --namespace "$K8S_NAMESPACE" 2>/dev/null)"; then
                    set +e
                    JOB_POD="$(echo "$JOB_DESCRIPTION" | grep SuccessfulCreate | grep 'Created pod' | awk '{print $NF}')"
                    set -e
                    if [ -n "$JOB_POD" ]; then
                        msg stage "Job \"$JOB_NAME\" is running on pod: '$JOB_POD'"
                    fi
                fi
            fi
        fi

        if [ -n "$JOB_POD" ]; then
            if ! JOB_POD_PHASE="$(kubectl get pod "$JOB_POD" --namespace "$K8S_NAMESPACE" --output jsonpath='{.status.phase}')"; then
                exitWithError "Could not get phase for the job pod \"$JOB_POD\""
            fi
            if [ "$JOB_POD_PHASE" = "Running" ]; then
                break
            fi
        fi

        if [ "$(expr $(date "+%s") - $START_TIME)" -ge "$TIMEOUT" ]; then
            exitWithError "Timeout while waiting for job \"$JOB_NAME\""
        fi

        MSG="Not ready pods: "
        unset MORE

        while IFS= read -r line; do
            POD_READY="$(echo "$line" | awk '{print $2}')"
            POD_STATUS="$(echo "$line" | awk '{print $3}')"
            [ "$POD_STATUS" = "Completed" ] && continue
            [ "${POD_READY%%/*}" != "0" ] && [ "$POD_STATUS" = "Running" ] && continue
            POD_NAME="$(echo "$line" | awk '{print $1}')"
            if [ -n "$MORE" ]; then
                MSG="$MSG, "
            else
                MORE=1
            fi
            if [ "$POD_STATUS" != "Running" ]; then
                MSG="$MSG\"$POD_NAME\" - $POD_STATUS"
            else
                MSG="$MSG\"$POD_NAME\" - not ready"
            fi
        done <<EOF
            $(kubectl get pods --namespace "$K8S_NAMESPACE" | tail -n +2)
EOF

        # msg debug "Waiting for the \"$JOB_NAME\" to be available..."
        msg info "$MSG"

        COUNT=0
        while [ "$COUNT" -lt 10 ]; do
            checkHelmAlive
            sleep 1
            COUNT=$(( COUNT + 1 ))
        done

    done

}

checkHelmAlive() {
    kill -0 "$HELM_PID" 2>/dev/null || exitWithError
}

checkEventsAlive() {

    if [ -n "$EVENTS_PID" ]; then
        if ! kill -0 "$EVENTS_PID"; then
            unset EVENTS_PID
        fi
    fi

    if [ -z "$EVENTS_PID" ]; then
        log kubectl get events --namespace "$K8S_NAMESPACE" --watch 2>/dev/null >"cluster-events.log" &
        EVENTS_PID=$!
    fi

}

checkDockerRegistryAccess() {
    if echo "$DOCKER_REGISTRY" | grep --silent '^gcr.io'; then
        msg "Updating docker registry secret ..."
        log kubectl delete secret gcr-access-token --namespace "$K8S_NAMESPACE" || true
        kubectl create secret docker-registry gcr-access-token --namespace "$K8S_NAMESPACE" \
            --docker-server=gcr.io \
            --docker-username=oauth2accesstoken \
            --docker-email="$(gcloud config list account --format "value(core.account)")" \
            --docker-password="$(gcloud auth print-access-token)"
        # patch the default serviceaccount for zookeeper chart
        kubectl patch serviceaccount default --namespace "$K8S_NAMESPACE" -p '{"imagePullSecrets": [{"name": "gcr-access-token"}]}'
        HELM_ARGS="$HELM_ARGS --set images.imagePullSecrets=gcr-access-token"
    fi
}

checkDockerLatestTag() {

    local TAGS
    local BUILD_NUMBERS
    local BUILD_NUMBER

    if [ "$DOCKER_TAG" != "latest" ]; then
        return
    fi

    msg "The latest tag is detected and will be converted to a real tag"

    if echo "$DOCKER_REGISTRY" | grep --silent '^gcr.io'; then
        # by default list-tags sorts by timestamp
        # https://cloud.google.com/sdk/gcloud/reference/container/images/list-tags
        DOCKER_TAG="$(log gcloud container images list-tags "$DOCKER_REGISTRY/cbflow-server" --filter="tags:build-*" --limit 1 --format "value(tags[0])")"
    elif echo "$DOCKER_REGISTRY" | grep --silent '^docker.io'; then
        # magic here!
        # get tags
        TAGS="$(curl --silent "https://registry.hub.docker.com/v1/repositories/${DOCKER_REGISTRY#*/}/cbflow-server/tags" | grep --perl-regexp --only-matching '"name": "\K[^"]+')"
        # convert to build numbers
        BUILD_NUMBERS="$(echo "$TAGS" | grep --perl-regexp --only-matching '\d+\.\d+\.\d+\.\K\d+')"
        # get the latest build number
        BUILD_NUMBER="$(echo "$BUILD_NUMBERS" | sort --numeric-sort --reverse | head -n 1)"
        # get a tag with the latest build number
        DOCKER_TAG="$(echo "$TAGS" | grep --fixed-strings ".${BUILD_NUMBER}_")"
    else
        msg error "Unknown docker registry: $DOCKER_REGISTRY"
        exit 1
    fi

    msg "The real tag is: $DOCKER_TAG"

}

updateHelmRepo() {
    if [ -e "$HELM_CHART" ]; then
        msg "Update dependencies for local chart..."
        log helm dependency update "$HELM_CHART"
    else
        msg "Update CloudBees public helm repository..."
        if ! helm repo list | grep --silent --perl-regexp '^cloudbees\s+'; then
            log helm repo add cloudbees https://public-charts.artifacts.cloudbees.com/repository/public/
        fi
        log helm repo update cloudbees
    fi
}

trap_handler() {
    EXIT_CODE=$?
    SIGNAL=$1
    msg debug "EXIT - Signal: $SIGNAL; Exit code: $EXIT_CODE; helm PID: $HELM_PID"
    if [ "$SIGNAL" = "0" ]; then
        # Normal exit
        # If the exit was due to an error, then kill helm process
        [ "$EXIT_CODE" != "0" ] && [ -n "$HELM_PID" ] && kill $HELM_PID >/dev/null 2>&1 || true
        [ -n "$EVENTS_PID" ] && kill "$EVENTS_PID" >/dev/null 2>&1 || true
        exit $EXIT_CODE
    fi
    # Exit by signal
    [ -n "$HELM_PID" ] && kill $HELM_PID >/dev/null 2>&1 || true
    [ -n "$EVENTS_PID" ] && kill "$EVENTS_PID" >/dev/null 2>&1 || true
    exit $(( SIGNAL + 128 ))
}
for i in 0 1 2 3 15; do trap "trap_handler $i" $i; done

# Cluster availability check.
# If the cluster is unavailable, the error will be displayed on stderr.
if ! helm ls >/dev/null; then
    exit $?
fi

initColors

if [ "$CBCD_DEMO_MODE" = "1" ]; then
    # use wait flag for helm to avoid exit before full initialization in non-cluster mode
    #HELM_ARGS="$HELM_ARGS --set clusteredMode=false --set mariadb.enabled=true --wait"
    HELM_ARGS="$HELM_ARGS --set clusteredMode=false --wait"
fi

if [ -n "$1" ]; then
    ACTION="$1"
    shift
else
    ACTION="install"
fi

if [ -n "$1" ] && [ "${1#-}" = "$1" ]; then
    HELM_CHART="$1"
    shift
fi

if [ "$ACTION" = "install" ] || [ "$ACTION" = "uninstall" ] || [ "$ACTION" = "info" ]; then
    $ACTION "$@"
else
    msg error "Unknown action '$ACTION'"
    exit 1
fi
