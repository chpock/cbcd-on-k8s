#!/bin/sh

# Copyright (c) 2022 CloudBees, Inc.
# All rights reserved.

set -e

IAM="kkushnir"
REGION="us-west2"
ZONE="${REGION}-a"
PROJECT="flow-testing-project"

# Machine type:
#
#   $ gcloud compute machine-types list --zones=us-west2-a
#
#   e2-standard-4  - 4 CPU 16 GB RAM
#   e2-standard-8  - 8 CPU 32 GB RAM
#   n2d-standard-4 - 4 CPU 16 GB RAM
#   n2d-standard-8 - 8 CPU 32 GB RAM
#
#   E2 - General-purpose workloads, Cost-optimized
#   N2, N2D, N1 - General-purpose workloads, Balanced
#   C2, C2D - Optimized workloads, Compute-optimized
#
#   https://cloud.google.com/compute/docs/machine-types
#

K8S_NODE_MACHINE="n2d-standard-8"

# unused as for now:
#NETWORK="projects/ops-shared-vpc/global/networks/ops-vpc1"
#SUBNETWORK="testing-cloud-cd-dev"

KUBECONFIG="$(pwd)/.kubeconfig.yaml"
export KUBECONFIG

if [ "$1" = "-silent" ]; then
    SILENT=1
    shift
fi

log() {

    if [ "$1" = "-noerror" ]; then
        shift
        (set -x; "$@" 2>&1)
    else
        (set -x; "$@")
    fi

}

msg() {
    if [ "$1" = "error" ]; then
        echo "ERROR: $2" >&2
        exit 1
    fi
    if [ -n "$SILENT" ]; then
        return
    fi
    if [ "$1" = "stage" ]; then
        echo
        echo "####################"
        echo "# $2"
        echo "####################"
    else
        echo "* $1"
    fi
}

random() {

    local LOWER_CASE
    local CHARS

    if [ "$1" = "-lowercase" ]; then
        LOWER_CASE=1
        shift
    else
        LOWER_CASE=0
    fi

    CHARS="$1"

    if [ -z "$CHARS" ]; then
        CHARS=32
    fi

    if [ "$LOWER_CASE" = "1" ]; then
        cat /dev/urandom | tr -dc 'a-z0-9' | fold -w $CHARS | head -n 1
    else
        cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $CHARS | head -n 1
    fi

}

kubeconfig() {

    eval "$(_common kubeconfig "$@")"

    local CLUSTER_NAME="$(cluster get name)"
    local I_NAME="gke_${PROJECT}_${ZONE}_$CLUSTER_NAME"

    if [ "$1" = "fetch" ]; then

        log -noerror kubectl config view >"$PROPS"
        if [ "$(kubeconfig get 'contexts[0].context.cluster')" != "$I_NAME" ]; then
            return 1
        fi

    elif [ "$1" = "check" ]; then

        msg "kubeconfig state: OK"

    elif [ "$1" = "start" ]; then

        # Hack for cygwin
        if [ "$(uname -o)" = "Cygwin" ] && [ -n "$KUBECONFIG" ]; then
            KUBECONFIG_SAVE="$KUBECONFIG"
            KUBECONFIG="$(cygpath -u "$KUBECONFIG")"
            export KUBECONFIG
        fi

        log gcloud container clusters get-credentials "$CLUSTER_NAME" --zone="$ZONE" --project="$PROJECT" --quiet

        # Revert the hack for cygwin
        if [ -n "$KUBECONFIG_SAVE" ]; then
            KUBECONFIG="$KUBECONFIG_SAVE"
            export KUBECONFIG
            unset KUBECONFIG_SAVE
        fi

        $CMD check

    elif [ "$1" = "stop" ]; then

        _noop

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}


vpc() {

    eval "$(_common vpc "$@")"

    local I_NAME="$IAM-k8s-dev"

    if [ "$1" = "fetch" ]; then

        log -noerror gcloud compute networks describe "$I_NAME" >"$PROPS"

    elif [ "$1" = "check" ]; then

        msg "VPC state: OK"

    elif [ "$1" = "start" ]; then

        log gcloud compute networks create "$I_NAME" \
            --subnet-mode=custom \
            --project=$PROJECT

        # log gcloud compute addresses create google-managed-services-$I_NAME \
        #     --global \
        #     --purpose=VPC_PEERING \
        #     --prefix-length=16 \
        #     --description="peering range for Google" \
        #     --network=$I_NAME \
        #     --project=$PROJECT

        # log gcloud services vpc-peerings connect \
        #     --service=servicenetworking.googleapis.com \
        #     --ranges=google-managed-services-$I_NAME \
        #     --network=$I_NAME \
        #     --project=$PROJECT

        $CMD check

    elif [ "$1" = "stop" ]; then

        local i

        for i in $(log gcloud compute firewall-rules list --filter network=$I_NAME --format="table[no-heading](name)"); do
            log gcloud compute firewall-rules delete "$i" --quiet || true
        done
        # log gcloud services vpc-peerings delete --quiet \
        #     --service=servicenetworking.googleapis.com \
        #     --network=$I_NAME \
        #     --project=$PROJECT || true
        # log gcloud compute addresses delete google-managed-services-$I_NAME --global --quiet || true
        log gcloud compute networks delete "$I_NAME" --quiet

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}

subnet() {

    eval "$(_common subnet "$@")"

    local I_NAME="$IAM-tier-1"

    if [ "$1" = "fetch" ]; then

        log -noerror gcloud compute networks subnets describe "$I_NAME" --region="$REGION" >"$PROPS"

    elif [ "$1" = "check" ]; then

        msg "Subnetwork state: OK"

    elif [ "$1" = "start" ]; then

        log gcloud compute networks subnets create "$I_NAME" \
            --network="$(vpc get name)" \
            --range=10.0.4.0/22 \
            --region="$REGION" \
            --secondary-range services=10.0.32.0/20,pods=10.4.0.0/14

        log gcloud compute firewall-rules create allow-int-"$I_NAME" \
            --network="$(vpc get name)" \
            --source-ranges=10.0.4.0/22,10.0.32.0/20,10.4.0.0/14 \
            --direction=ingress \
            --rules=all \
            --action=allow

        $CMD check

    elif [ "$1" = "stop" ]; then

        log gcloud compute networks subnets delete "$I_NAME" --region="$REGION" --quiet

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}

#db() {
#
#    local I_NAME="$IAM-$(random -lowercase 6)-db-mysql-57"
#    local RESULT
#
#    if [ "$1" = "get" ]; then
#        [ -z "$TEMP_FILE_DB_PROPS" ] && msg error "Could not find database file"
#        yq e ".$2" "$(cygpath -m "$TEMP_FILE_DB_PROPS")"
#        return
#    fi
#
#    msg "Check database..."
#
#    if RESULT="$(log -noerror gcloud sql instances describe "$I_NAME")"; then
#        TEMP_FILE_DB_PROPS="$(mktemp --suffix="-k8s-env-db-$IAM")"
#        echo "$RESULT" >"$TEMP_FILE_DB_PROPS"
#        if [ "$1" = "start" ]; then
#            msg "Database already exists: $(db get state)"
#            return
#        fi
#    else
#        if [ "$1" = "check" ] || [ "$1" = "stop" ]; then
#            msg "Database doesn't exist"
#            return
#        elif [ "$1" != "start" ]; then
#            msg error "Database doesn't exist"
#        fi
#    fi
#
#    if [ "$1" = "check" ]; then
#        msg "Database state: $(db get state)"
#    fi
#
#    if [ "$1" = "describe" ]; then
#        yq "$(cygpath -m "$TEMP_FILE_DB_PROPS")"
#    fi
#
#    if [ "$1" = "start" ]; then
#
#        msg "Create database..."
#
#        # Tier:
#        #   db-f1-micro - shared CPU / 0.6 GB RAM / 3,062 GB max storage
#        #   db-g1-small - shared CPU / 1.7 GB RAM / 3,062 GB max storage
#        # DB versions:
#        #   MYSQL_5_6,MYSQL_5_7, MYSQL_8_0, POSTGRES_9_6, POSTGRES_10, POSTGRES_11,
#        #   POSTGRES_12, POSTGRES_13, POSTGRES_14, SQLSERVER_2017_EXPRESS,
#        #   SQLSERVER_2017_WEB, SQLSERVER_2017_STANDARD, SQLSERVER_2017_ENTERPRISE,
#        #   SQLSERVER_2019_EXPRESS, SQLSERVER_2019_WEB, SQLSERVER_2019_STANDARD,
#        #   SQLSERVER_2019_ENTERPRISE.
#        log gcloud sql instances create "$I_NAME" \
#            --tier=db-f1-micro \
#            --assign-ip \
#            --availability-type=zonal \
#            --no-backup \
#            --database-version=MYSQL_5_7 \
#            --network=default \
#            --password-policy-complexity=COMPLEXITY_UNSPECIFIED \
#            --require-ssl \
#            --root-password="${IAM}pass" \
#            --storage-auto-increase \
#            --zone=$ZONE \
#            --project=$PROJECT
#
#        db check
#
#    fi
#
#    if [ "$1" = "stop" ]; then
#        msg "Stop database..."
#        log gcloud sql instances delete "$I_NAME" --quiet
#    fi
#
#}

db() {

    eval "$(_common db "$@")"

    local DB_NAMESPACE="db"
    local DB_RELEASE="mysql-5-7"
    # from https://hub.docker.com/r/bitnami/mysql/tags
    local DB_TAG="5.7.37-debian-10-r95"

    if [ "$1" = "fetch" ]; then

        if helm list --namespace $DB_NAMESPACE --superseded --deployed --failed --pending --filter $DB_RELEASE | grep --silent "$DB_RELEASE"; then
            kubectl get secret --namespace $DB_NAMESPACE $DB_RELEASE -o yaml >"$PROPS"
        else
            return 1
        fi

    elif [ "$1" = "check" ]; then

        msg "DB state: OK"

    elif [ "$1" = "start" ]; then

        if ! helm repo list --output table | grep --silent '^bitnami\s'; then
            log helm repo add bitnami https://charts.bitnami.com/bitnami
        fi

        log helm repo update bitnami
        log helm upgrade $DB_RELEASE bitnami/mysql --install --namespace $DB_NAMESPACE --create-namespace \
            --set image.tag=$DB_TAG \
            --set auth.database=commander \
            --set image.debug=true \
            --wait --wait-for-jobs --timeout 5m0s

    elif [ "$1" = "stop" ]; then

        log helm uninstall $DB_RELEASE --namespace $DB_NAMESPACE
        log kubectl delete namespace $DB_NAMESPACE --wait=true

    elif [ "$1" = "info" ]; then

        msg "Use the following parameters for helm install:"
        echo "--set database.dbType=mysql --set database.dbName=commander --set database.dbUser=root --set database.dbPassword=\"$($CMD get data.mysql-root-password | base64 -d)\" --set database.clusterEndpoint=$DB_RELEASE.$DB_NAMESPACE" --set database.dbPort=3306

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}

_noop() {
    local noop=noop
}

_props() {
    local TEMP_VAR="TEMP_FILE_PROPS_$1"
    local TEMP_VAL="$(eval echo \$$TEMP_VAR)"
    if [ -z "$TEMP_VAL" ]; then
        TEMP_VAL="$(mktemp --suffix="-k8s-env-$1-$IAM")"
        eval "$TEMP_VAR=\"$TEMP_VAL\""
        CLEANUP_TEMP_FILES="$TEMP_VAL $CLEANUP_TEMP_FILES"
    fi
    [ "$(uname -o)" = "Cygwin" ] && TEMP_VAL="$(cygpath -m "$TEMP_VAL")"
    echo "local PROPS=\"$TEMP_VAL\""
    echo "$TEMP_VAR=\"$TEMP_VAL\""
    echo "CLEANUP_TEMP_FILES=\"$CLEANUP_TEMP_FILES\""
}

_common() {

    local CMD="$1"
    shift

    local _="$(_props $CMD)"
    eval "$_"

    echo "$_"
    echo "local CMD=\"$CMD\""

    if [ "$1" = "fetch" ]; then
        return
    fi

    if [ "$1" = "start" ]; then
        msg stage "$CMD: starting..." >&2
    elif [ "$1" = "check" ]; then
        msg stage "$CMD: checking..." >&2
    elif [ "$1" = "stop" ]; then
        msg stage "$CMD: stopping..." >&2
    elif [ "$1" = "refresh" ]; then
        msg stage "$CMD: refreshing..." >&2
    fi

    if [ ! -s "$PROPS" ]; then
        if ! $CMD fetch; then
            if [ "$1" = "check" ] || [ "$1" = "info" ] || [ "$1" = "get" ] || [ "$1" = "describe" ] || [ "$1" = "refresh" ]; then
                echo "exit 1"
                msg error "$CMD: does not exist" >&2
            elif [ "$1" = "stop" ]; then
                msg "$CMD: does not exist" >&2
                echo "return"
                return
            fi
        else
            if [ "$1" = "start" ]; then
                msg "$CMD: already exists" >&2
                echo "return"
                return
            fi
        fi
    fi

    if [ "$1" = "get" ]; then
        echo "yq e \".\$2\" \"$PROPS\""
        echo "return"
        return
    elif [ "$1" = "describe" ]; then
        echo "yq -C e \"$PROPS\""
        echo "return"
        return
    fi

    return

}

#template() {
#
#    eval "$(_common <cmd> "$@")"
#
#    if [ "$1" = "fetch" ]; then
#    elif [ "$1" = "check" ]; then
#    elif [ "$1" = "start" ]; then
#    elif [ "$1" = "stop" ]; then
#    elif [ "$1" = "info" ]; then
#    elif [ "$1" = "refresh" ]; then
#    else
#        msg error "$CMD: unsupported cmd $1"
#    fi
#}

cluster() {

    eval "$(_common cluster "$@")"

    local I_NAME="$IAM-dev"

    if [ "$1" = "fetch" ]; then

        log -noerror gcloud container clusters describe "$I_NAME" --zone=$ZONE >"$PROPS"

    elif [ "$1" = "check" ]; then

        msg "K8s cluster state: $($CMD get status)"

    elif [ "$1" = "start" ]; then

        # Hack for cygwin
        if [ "$(uname -o)" = "Cygwin" ] && [ -n "$KUBECONFIG" ]; then
            KUBECONFIG_SAVE="$KUBECONFIG"
            KUBECONFIG="$(cygpath -u "$KUBECONFIG")"
            export KUBECONFIG
        fi

        # auth notes:
        # by default, client certificate (--issue-client-certificate) doesn't work with RBAC:
        #     * https://github.com/googleapis/google-api-go-client/issues/278
        #     * https://stackoverflow.com/questions/58976517/gke-masterauth-clientcertificate-has-no-permissions-to-access-cluster-resource
        # but it works for ABAC. That is why --enable-legacy-authorization was specified.
        # After creating the cluster we will do some magic and add the cluster-admin rights for the current user.

        # Release channels:
        #   None rapid regular stable
        log gcloud container clusters create "$I_NAME" \
            --enable-legacy-authorization \
            --issue-client-certificate \
            --release-channel=stable \
            --num-nodes=3 \
            --enable-network-policy \
            --disk-size=100 \
            --disk-type=pd-standard \
            --machine-type=$K8S_NODE_MACHINE \
            --preemptible \
            --logging=SYSTEM,WORKLOAD \
            --network="$(vpc get name)" \
            --enable-ip-alias \
            --cluster-secondary-range-name=pods \
            --services-secondary-range-name=services \
            --subnetwork="$(subnet get name)" \
            --zone=$ZONE \
            --project=$PROJECT

        # Revert the hack for cygwin
        if [ -n "$KUBECONFIG_SAVE" ]; then
            KUBECONFIG="$KUBECONFIG_SAVE"
            export KUBECONFIG
            unset KUBECONFIG_SAVE
        fi

        $CMD check

        # Magic here!
        local CRT_FILE="$(mktemp --suffix="-k8s-env-cluster-crt-$IAM")"
        local KEY_FILE="$(mktemp --suffix="-k8s-env-cluster-key-$IAM")"
        [ "$(uname -o)" = "Cygwin" ] && CRT_FILE="$(cygpath -m "$CRT_FILE")" || true
        [ "$(uname -o)" = "Cygwin" ] && KEY_FILE="$(cygpath -m "$KEY_FILE")" || true
        cluster get masterAuth.clientCertificate | base64 -d >"$CRT_FILE"
        cluster get masterAuth.clientKey | base64 -d >"$KEY_FILE"
        log kubectl --client-certificate "$CRT_FILE" --client-key "$KEY_FILE" \
            create clusterrolebinding "$IAM-rights-binding" --clusterrole cluster-admin \
            --user "$(gcloud config list account --format "value(core.account)")"
        rm -f "$CRT_FILE" "$KEY_FILE"
        # disable ABAC
        log gcloud container clusters update "$I_NAME" --zone=$ZONE --no-enable-legacy-authorization

        if ! helm repo list --output table | grep --silent '^nfs-subdir-external-provisioner\s'; then
            log helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
        fi

        log helm repo update nfs-subdir-external-provisioner
        log helm upgrade nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner --install \
            --namespace default --create-namespace \
            --wait --wait-for-jobs --timeout 5m0s \
            --set nfs.server="$(filestore get 'networks[0].ipAddresses[0]')" \
            --set nfs.path="/$(filestore get 'fileShares[0].name')"

    elif [ "$1" = "stop" ]; then

        log gcloud container clusters delete "$I_NAME" --zone=$ZONE --quiet

    elif [ "$1" = "info" ]; then

        msg "Use the following parameters for helm install:"
        echo "--set platform=gke --set storage.volumes.serverPlugins.storageClass=nfs-client --set storage.volumes.serverPlugins.storage=10Gi"

    elif [ "$1" = "refresh" ]; then

        for i in $(log kubectl get namespaces --output jsonpath="{.items[*].metadata.name}"); do
            if [ "$i" = "default" ] || [ "$i" = "kube-node-lease" ] || [ "$i" = "kube-public" ] || [ "$i" = "kube-system" ]; then
                continue
            fi
            log kubectl delete namespace $i --wait=true
        done

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}

filestore() {

    eval "$(_common filestore "$@")"

    local I_NAME="$IAM-k8s-fs"

    if [ "$1" = "fetch" ]; then

        log -noerror gcloud filestore instances describe "$I_NAME" --location=$ZONE >"$PROPS"

    elif [ "$1" = "check" ]; then

        msg "filestore state: $($CMD get state)"

    elif [ "$1" = "start" ]; then

        # Capacity in GB
        # Tiers: standard enterprise
        log gcloud filestore instances create "$I_NAME" \
            --file-share=capacity=1024,name=filestore \
            --network=name="$(vpc get name)" \
            --tier=standard \
            --location=$ZONE \
            --project=$PROJECT

        $CMD check

    elif [ "$1" = "stop" ]; then

        log gcloud filestore instances delete "$I_NAME" --location=$ZONE --quiet

    else
        msg error "$CMD: unsupported cmd $1"
    fi

}

if ! command -v yq; then

    IMAGE_YQ="mikefarah/yq:4.13.5"

    docker inspect --type=image "$IMAGE_YQ" >/dev/null 2>&1 || docker pull --quiet "$IMAGE_YQ"

    yq() {
        local CURRENT_USER="$(id -u ${USER}):$(id -g ${USER})"
        local FN
        for FN; do :; done;
        # don't add -t here to avoid CR (^M) in output:
        # https://github.com/moby/moby/issues/37366
        docker run -i --rm --user "$CURRENT_USER" -v "$PWD:/workdir" -v "$FN:$FN" "$IMAGE_YQ" "$@"
    }

fi

start() {
    vpc start
    subnet start
    filestore start
    cluster start
    kubeconfig start
    db start
}

check() {
    vpc check
    subnet check
    filestore check
    cluster check
    kubeconfig check
    db check
}

describe() {
    vpc describe
    subnet describe
    filestore describe
    cluster describe
    kubeconfig describe
    db describe
}

stop() {
    cluster stop
    filestore stop
    subnet stop
    vpc stop
    kubeconfig stop
}

restart() {
    stop
    start
}

refresh() {
    db stop
    cluster refresh
    db start
}

info() {
    cluster info
    db info
}

_on_exit() {
    for i in $CLEANUP_TEMP_FILES; do rm -f "$i"; done
    true
}

trap _on_exit EXIT

"$@"
