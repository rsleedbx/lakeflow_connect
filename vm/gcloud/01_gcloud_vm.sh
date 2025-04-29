#!/usr/bin/env bash


GCLOUD_INIT

export GCLOUD_FW_RULE_NAME="${WHOAMI}-fwr-22-1433"
export DB_HOST="${DB_HOST:-$WHOAMI-$DB_BASENAME}"

# #############################################################################
# create sql server

echo -e "\nCreate database compute if not exists"
echo -e   "-------------------------------------\n"

firewall_create() {
    if ! GCLOUD compute firewall-rules describe "${GCLOUD_FW_RULE_NAME}"; then
        printf -v DB_FIREWALL_CIDRS_CSV '%s,' "${DB_FIREWALL_CIDRS[@]}"
        DB_FIREWALL_CIDRS_CSV="${DB_FIREWALL_CIDRS_CSV%,}"  # remove trailing ,

        GCLOUD compute firewall-rules create "${GCLOUD_FW_RULE_NAME}" \
            --allow tcp:22,tcp:1433 \
            --source-ranges "${DB_FIREWALL_CIDRS_CSV}" \
            --target-tags "${GCLOUD_FW_RULE_NAME}" \
            --network default
    fi
    #DB_EXIT_ON_ERROR="PRINT_EXIT" GCLOUD compute instances add-tags "$DB_HOST" --tags="${GCLOUD_FW_RULE_NAME}"
}
export -f firewall_create
firewall_create

using_tf() {
    terraform init -auto-approve
    terraform plan -auto-approve
    terraform apply -auto-approve
}

# e2-micro
# e2-medium 2x4 = $24 month required for DB to startup
# e2-small 2x2 = $13 month
# e2-micro 1x1 = $7 month

if ! GCLOUD compute instances describe "$DB_HOST"; then 
    labels=""
    labels="${DBX_USERNAME_NO_DOMAIN_DOT:+${labels}owner=${DBX_USERNAME_NO_DOMAIN_DOT,,}},"  # ,,=lower case
    labels="${REMOVE_AFTER:+${labels}removeafter=${REMOVE_AFTER}}"
    DB_EXIT_ON_ERROR="PRINT_EXIT" GCLOUD compute instances create "$DB_HOST" \
        --labels="$labels" \
        --project="$GCLOUD_PROJECT" \
        --zone="$GCLOUD_ZONE" \
        --machine-type=e2-medium \
        --network-interface=network-tier=PREMIUM,stack-type=IPV4_ONLY,subnet=default \
        ${GCLOUD_FW_RULE_NAME:+--tags ${GCLOUD_FW_RULE_NAME}} \
        --metadata="enable-osconfig=TRUE,ssh-keys=${WHOAMI_USERNAME}:$(<~/.ssh/id_rsa.pub)" \
        --maintenance-policy=MIGRATE \
        --provisioning-model=STANDARD \
        --create-disk=auto-delete=yes,boot=yes,device-name=$DB_HOST,disk-resource-policy=projects/$GCLOUD_PROJECT/regions/$GCLOUD_REGION/resourcePolicies/default-schedule-1,image=projects/ubuntu-os-cloud/global/images/ubuntu-2404-noble-amd64-v20250425,mode=rw,size=50,type=pd-balanced

    if [[ -n "${STOP_AFTER_SLEEP}" ]]; then 
        nohup sleep "${STOP_AFTER_SLEEP}" && GCLOUD compute instances stop "$DB_HOST">> ~/nohup.out 2>&1 &
    fi
    DB_HOST_FQDN=$(jq -r '.[] | .networkInterfaces.[] | .accessConfigs.[] | select(.name="external-nat") | .natIP' /tmp/gcloud_stdout.$$ )

else
    DB_HOST_FQDN=$(jq -r '.networkInterfaces.[] | .accessConfigs.[] | select(.name="external-nat") | .natIP' /tmp/gcloud_stdout.$$ )
fi

echo "gcloud compute ssh \$DB_HOST"
echo "ssh \$DB_HOST_FQDN"