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

if [ "$1" = "-silent" ]; then
    SILENT=1
    shift
fi

log() {
    (set -x; "$@")
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


vpc() {

    local I_NAME="$IAM-k8s-dev"
    local i

    [ -z "$TEMP_FILE_VPC_PROPS" ] && TEMP_FILE_VPC_PROPS="$(mktemp --suffix="-k8s-env-vpc-$IAM")"
    local FILE_PROPS="$TEMP_FILE_VPC_PROPS"
    [ "$(uname -o)" = "Cygwin" ] && FILE_PROPS="$(cygpath -m "$FILE_PROPS")"

    if [ "$1" = "get" ]; then
        [ ! -s "$FILE_PROPS" ] && vpc check
        yq e ".$2" "$FILE_PROPS"
        return
    fi

    msg stage "Check VPC..."

    if log gcloud compute networks describe "$I_NAME" 2>/dev/null >"$FILE_PROPS"; then
        if [ "$1" = "start" ]; then
            msg "VPC already exists"
            return
        fi
    else
        if [ "$1" = "check" ] || [ "$1" = "stop" ]; then
            msg "VPC doesn't exist"
            return
        elif [ "$1" != "start" ]; then
            msg error "VPC doesn't exist"
        fi
    fi

    if [ "$1" = "check" ]; then
        msg "VPC state: OK"
    fi

    if [ "$1" = "describe" ]; then
        yq "$FILE_PROPS"
    fi

    if [ "$1" = "start" ]; then

        msg stage "Create VPC..."

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

        vpc check

    fi

    if [ "$1" = "stop" ]; then
        msg stage "Stop VPC..."
        for i in $(log gcloud compute firewall-rules list --filter network=$I_NAME --format="table[no-heading](name)"); do
            log gcloud compute firewall-rules delete "$i" --quiet || true
        done
        # log gcloud services vpc-peerings delete --quiet \
        #     --service=servicenetworking.googleapis.com \
        #     --network=$I_NAME \
        #     --project=$PROJECT || true
        # log gcloud compute addresses delete google-managed-services-$I_NAME --global --quiet || true
        log gcloud compute networks delete "$I_NAME" --quiet
    fi

}

subnet() {

    local I_NAME="$IAM-tier-1"

    [ -z "$TEMP_FILE_SUBNET_PROPS" ] && TEMP_FILE_SUBNET_PROPS="$(mktemp --suffix="-k8s-env-subnet-$IAM")"
    local FILE_PROPS="$TEMP_FILE_SUBNET_PROPS"
    [ "$(uname -o)" = "Cygwin" ] && FILE_PROPS="$(cygpath -m "$FILE_PROPS")"

    if [ "$1" = "get" ]; then
        [ ! -s "$FILE_PROPS" ] && subnet check
        yq e ".$2" "$FILE_PROPS"
        return
    fi

    msg stage "Check subnetwork..."

    if log gcloud compute networks subnets describe "$I_NAME" --region="$REGION" 2>/dev/null >"$FILE_PROPS"; then
        if [ "$1" = "start" ]; then
            msg "Subnetwork already exists"
            return
        fi
    else
        if [ "$1" = "check" ] || [ "$1" = "stop" ]; then
            msg "Subnetwork doesn't exist"
            return
        elif [ "$1" != "start" ]; then
            msg error "Subnetwork doesn't exist"
        fi
    fi

    if [ "$1" = "check" ]; then
        msg "Subnetwork state: OK"
    fi

    if [ "$1" = "describe" ]; then
        yq "$FILE_PROPS"
    fi

    if [ "$1" = "start" ]; then

        msg stage "Create subnetwork..."

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

        subnet check

    fi

    if [ "$1" = "stop" ]; then
        msg stage "Stop subnetwork..."
        log gcloud compute networks subnets delete "$I_NAME" --region="$REGION" --quiet
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
#    if RESULT="$(log gcloud sql instances describe "$I_NAME" 2>/dev/null)"; then
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

    local DB_NAMESPACE="db"
    local DB_RELEASE="mysql-5-7"
    # from https://hub.docker.com/r/bitnami/mysql/tags
    local DB_TAG="5.7.37-debian-10-r95"

    [ -z "$TEMP_FILE_DB_PROPS" ] && TEMP_FILE_DB_PROPS="$(mktemp --suffix="-k8s-env-db-$IAM")"
    local FILE_PROPS="$TEMP_FILE_DB_PROPS"
    [ "$(uname -o)" = "Cygwin" ] && FILE_PROPS="$(cygpath -m "$FILE_PROPS")"

    if [ "$1" = "get" ]; then
        [ ! -s "$FILE_PROPS" ] && db check
        yq e ".$2" "$FILE_PROPS"
        return
    fi

    msg stage "Check db..."

    if helm list --namespace $DB_NAMESPACE --superseded --deployed --failed --pending --filter $DB_RELEASE | grep --silent "$DB_RELEASE"; then
        kubectl get secret --namespace $DB_NAMESPACE $DB_RELEASE -o yaml >"$FILE_PROPS"
        if [ "$1" = "start" ]; then
            msg "DB already exists"
            return
        fi
    else
        if [ "$1" = "check" ] || [ "$1" = "stop" ] || [ "$1" = "info" ]; then
            msg "DB doesn't exist"
            return
        elif [ "$1" != "start" ]; then
            msg error "DB doesn't exist"
        fi
    fi

    if [ "$1" = "check" ]; then
        msg "DB state: OK"
    fi

    if [ "$1" = "describe" ]; then
        yq "$FILE_PROPS"
    fi

    if [ "$1" = "start" ]; then

        msg stage "Create database..."

        if ! helm repo list --output table | grep --silent '^bitnami\s'; then
            log helm repo add bitnami https://charts.bitnami.com/bitnami
        fi

        log helm repo update bitnami
        log helm upgrade $DB_RELEASE bitnami/mysql --install --namespace $DB_NAMESPACE --create-namespace \
            --set image.tag=$DB_TAG \
            --set auth.database=commander \
            --set image.debug=true \
            --wait --wait-for-jobs --timeout 5m0s

    fi

    if [ "$1" = "stop" ]; then
        msg stage "Stop database ..."
        log helm uninstall $DB_RELEASE --namespace $DB_NAMESPACE
        log kubectl delete namespace $DB_NAMESPACE --wait=true
    fi

    if [ "$1" = "info" ]; then
        msg "Use the following parameters for helm install:"
        echo "--set database.dbType=mysql --set database.dbName=commander --set database.dbUser=root --set database.dbPassword=\"$(db get data.mysql-root-password | base64 -d)\" --set database.clusterEndpoint=$DB_RELEASE.$DB_NAMESPACE" --set database.dbPort=3306
    fi

}

cluster() {

    local I_NAME="$IAM-dev"

    [ -z "$TEMP_FILE_CLUSTER_PROPS" ] && TEMP_FILE_CLUSTER_PROPS="$(mktemp --suffix="-k8s-env-cluster-$IAM")"
    local FILE_PROPS="$TEMP_FILE_CLUSTER_PROPS"
    [ "$(uname -o)" = "Cygwin" ] && FILE_PROPS="$(cygpath -m "$FILE_PROPS")"

    if [ "$1" = "get" ]; then
        [ ! -s "$FILE_PROPS" ] && cluster check
        yq e ".$2" "$FILE_PROPS"
        return
    fi

    msg stage "Check cluster..."

    if log gcloud container clusters describe "$I_NAME" --zone=$ZONE 2>/dev/null >"$FILE_PROPS"; then
        if [ "$1" = "start" ]; then
            msg "K8s cluster already exists: $(cluster get status)"
            return
        fi
    else
        if [ "$1" = "check" ] || [ "$1" = "stop" ]; then
            msg "K8s cluster doesn't exist"
            return
        elif [ "$1" != "start" ]; then
            msg error "K8s cluster doesn't exist"
        fi
    fi

    if [ "$1" = "check" ]; then
        msg "K8s cluster state: $(cluster get status)"
        # Hack for cygwin
        if [ "$(uname -o)" = "Cygwin" ] && [ -n "$KUBECONFIG" ]; then
            KUBECONFIG_SAVE="$KUBECONFIG"
            KUBECONFIG="$(cygpath -u "$KUBECONFIG")"
            export KUBECONFIG
        fi
        log gcloud container clusters get-credentials "$I_NAME" --zone="$ZONE" --project="$PROJECT" --quiet
        # Revert the hack for cygwin
        if [ -n "$KUBECONFIG_SAVE" ]; then
            KUBECONFIG="$KUBECONFIG_SAVE"
            export KUBECONFIG
            unset KUBECONFIG_SAVE
        fi
    fi

    if [ "$1" = "describe" ]; then
        yq "$FILE_PROPS"
    fi

    if [ "$1" = "start" ]; then

        msg stage "Create k8s cluster..."

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

        cluster check

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

    fi

    if [ "$1" = "stop" ]; then
        msg stage "Stop k8s cluster..."
        log gcloud container clusters delete "$I_NAME" --zone=$ZONE --quiet
    fi

    if [ "$1" = "info" ]; then
        msg "Use the following parameters for helm install:"
        echo "--set platform=gke --set storage.volumes.serverPlugins.storageClass=nfs-client --set storage.volumes.serverPlugins.storage=10Gi"
    fi

    if [ "$1" = "refresh" ]; then

        local i

        for i in $(log kubectl get namespaces --output jsonpath="{.items[*].metadata.name}"); do
            if [ "$i" = "default" ] || [ "$i" = "kube-node-lease" ] || [ "$i" = "kube-public" ] || [ "$i" = "kube-system" ]; then
                continue
            fi
            log kubectl delete namespace $i --wait=true
        done

    fi

}

filestore() {

    local I_NAME="$IAM-k8s-fs"

    [ -z "$TEMP_FILE_FS_PROPS" ] && TEMP_FILE_FS_PROPS="$(mktemp --suffix="-k8s-env-fs-$IAM")"
    local FILE_PROPS="$TEMP_FILE_FS_PROPS"
    [ "$(uname -o)" = "Cygwin" ] && FILE_PROPS="$(cygpath -m "$FILE_PROPS")"

    if [ "$1" = "get" ]; then
        [ ! -s "$FILE_PROPS" ] && filestore check
        yq e ".$2" "$FILE_PROPS"
        return
    fi

    msg stage "Check filestore..."

    if log gcloud filestore instances describe "$I_NAME" --location=$ZONE 2>/dev/null >"$FILE_PROPS"; then
        if [ "$1" = "start" ]; then
            msg "Filestore already exists: $(filestore get state)"
            return
        fi
    else
        if [ "$1" = "check" ] || [ "$1" = "stop" ]; then
            msg "Filestore doesn't exist"
            return
        elif [ "$1" != "start" ]; then
            msg error "Filestore doesn't exist"
        fi
    fi

    if [ "$1" = "check" ]; then
        msg "filestore state: $(filestore get state)"
    fi

    if [ "$1" = "describe" ]; then
        yq "$FILE_PROPS"
    fi

    if [ "$1" = "start" ]; then

        msg stage "Create filestore ..."

        # Capacity in GB
        # Tiers: standard enterprise
        log gcloud filestore instances create "$I_NAME" \
            --file-share=capacity=1024,name=filestore \
            --network=name="$(vpc get name)" \
            --tier=standard \
            --location=$ZONE \
            --project=$PROJECT

        filestore check

    fi

    if [ "$1" = "stop" ]; then
        msg stage "Stop filestore..."
        log gcloud filestore instances delete "$I_NAME" --location=$ZONE --quiet
    fi

}

if ! command -v yq; then

    IMAGE_YQ="mikefarah/yq:4.13.5"

    docker inspect --type=image "$IMAGE_YQ" >/dev/null 2>&1 || docker pull --quiet "$IMAGE_YQ"

    yq() {
        local CURRENT_USER="$(id -u ${USER}):$(id -g ${USER})"
        local FN
        for FN; do :; done;
        docker run -i --rm --user "$CURRENT_USER" -v "$PWD:/workdir" -v "$FN:$FN" "$IMAGE_YQ" "$@"
    }

fi

start() {
    vpc start
    subnet start
    filestore start
    cluster start
    db start
}

check() {
    vpc check
    subnet check
    filestore check
    cluster check
    db check
}

describe() {
    vpc describe
    subnet describe
    filestore describe
    cluster describe
    db describe
}

stop() {
    cluster stop
    filestore stop
    subnet stop
    vpc stop
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
    [ -n "$TEMP_FILE_DB_PROPS" ]      && rm -f "$TEMP_FILE_DB_PROPS"
    [ -n "$TEMP_FILE_FS_PROPS" ]      && rm -f "$TEMP_FILE_FS_PROPS"
    [ -n "$TEMP_FILE_CLUSTER_PROPS" ] && rm -f "$TEMP_FILE_CLUSTER_PROPS"
    [ -n "$TEMP_FILE_VPC_PROPS" ]     && rm -f "$TEMP_FILE_VPC_PROPS"
    [ -n "$TEMP_FILE_SUBNET_PROPS" ]  && rm -f "$TEMP_FILE_SUBNET_PROPS"
    true
}

trap _on_exit EXIT

"$@"
