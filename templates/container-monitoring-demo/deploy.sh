#!/usr/bin/env sh

usage() {
    echo "Helper to deploy the environment."
    echo ""
    echo "$0"
    echo "\t-h --help"
    echo "\t-g --resourceGroup=$RESOURCEGROUP"
    echo "\t-e --environmentName=$ENVIRONMENTNAME"
	echo "\t-u --adminUsername=$ADMINUSERNAME"
	echo "\t-i --servicePrincipalId=$SERVICEPRINCIPALID"
	echo "\t-s --servicePrincipalSecret=$SERVICEPRINCIPALSECRET"
    echo ""
}

deployInfrastructure() {
    deploymentName=$1
    resourceGroup=$2
    environmentName=$3
    adminUsername=$4
    adminSshKey=$5
    servicePrincipalId=$6
    servicePrincipalSecret=$7

    parameters=$(cat << EOM
{
    "EnvironmentName": {
        "value": "${environmentName}"
    },
    "AdminUsername": {
        "value": "${adminUsername}"
    },
    "AdminSshKey": {
        "value": "ssh-rsa ${adminSshKey}"
    },
    "ServicePrincipalClientId": {
        "value": "${servicePrincipalId}"
    },
    "ServicePrincipalClientSecret": {
        "value": "${servicePrincipalSecret}"
    }
}
EOM
)

	echo "Running resource group deployment"
    az group deployment create \
        --resource-group $resourceGroup \
        --name $deploymentName \
        --template-file azuredeploy.json \
        --parameters "$parameters" 1> /dev/null
}

deployMonitoringAcs() {
    resourceGroup=$1
    name="$2"
    nameAcs="$name-acs"
    
    fqdn=$(az acs show -g $resourceGroup -n $nameAcs --query masterProfile.fqdn -o tsv)
    SSH="ssh -v -A labadmin@${fqdn} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    
    serviceId=$($SSH docker service ls --filter "name=omsagent" -q)

    if [ "$serviceId" = "" ]; then
        resourceId=$(az resource list -g $resourceGroup -n $name --resource-type "Microsoft.OperationalInsights/workspaces" --query [].id -o tsv)
        workspaceId=$(az resource show --ids $resourceId --query properties.customerId -o tsv)
        workspaceKey=$(az resource invoke-action --action sharedKeys --ids $resourceId | sed 's/\\r\\n//g' | sed 's/\\\"/"/g' | sed 's/"{/{/' | sed 's/}"/}/' | jq -r .primarySharedKey)

        echo "Creating secrets"
        $SSH "echo $workspaceId | docker secret create workspaceId -"
        $SSH "echo $workspaceKey | docker secret create workspaceKey -"

        echo "Creating OMS agent service"
        $SSH \
            "docker service create \
                --name omsagent \
                --mode global \
                --mount type=bind,source=/var/run/docker.sock,destination=/var/run/docker.sock \
                --secret source=workspaceId,target=WSID \
                --secret source=workspaceKey,target=KEY \
                -p 25225:25225 \
                -p 25224:25224/udp \
                --restart-condition=on-failure \
                microsoft/oms"
    else
        echo "OMS agent service is already created"
    fi
}

deployApplicationAcs() {
    resourceGroup=$1
    name="$2-acs"
}

deployApplicationAks() {
    resourceGroup=$1
    name="$2-aks"

	echo "Configuring Kubernetes credentials for CLI use"
	az aks get-credentials \
		--resource-group $resourceGroup \
		--name $name

	echo "Deploy application to AKS"
	kubectl apply -f minecraft.yaml
}

while [ "$1" != "" ]; do
    PARAM=`echo $1 | awk -F= '{print $1}'`
    VALUE=`echo $1 | sed 's/^[^=]*=//g'`
    case $PARAM in
        -h | --help)
            usage
            exit
            ;;
        -g | --resourceGroup)
            RESOURCEGROUP=$VALUE
            ;;
        -e | --environmentName)
            ENVIRONMENTNAME=$VALUE
            ;;
		-u | --adminUsername)
            ADMINUSERNAME=$VALUE
            ;;
		-k | --adminSshKey)
            ADMINSSHKEY=$VALUE
            ;;
		-i | --servicePrincipalId)
            SERVICEPRINCIPALID=$VALUE
            ;;
		-s | --servicePrincipalSecret)
            SERVICEPRINCIPALSECRET=$VALUE
            ;;
        *)
            echo "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done

if [ "$RESOURCEGROUP" = "" ] || [ "$ENVIRONMENTNAME" = "" ] || [ "$ADMINUSERNAME" = "" ]; then
	echo "ERROR: missing parameters"
	usage
	exit 1
fi

if [ "$SERVICEPRINCIPALID" = "" ] || [ "$SERVICEPRINCIPALSECRET" = "" ]; then
	echo "ERROR: missing parameters"
	usage
	exit 1
fi

deploymentName=`date +'%Y%m%d-%H%M%S'`
adminSshKey=$(cat ~/.ssh/id_rsa.pub)

deployInfrastructure \
    $deploymentName \
    $RESOURCEGROUP \
    $ENVIRONMENTNAME \
    $ADMINUSERNAME \
    $adminSshKey \
    $SERVICEPRINCIPALID \
    $SERVICEPRINCIPALSECRET

deployMonitoringAcs \
	$RESOURCEGROUP \
	$ENVIRONMENTNAME

# deployApplicationAcs \
#	$RESOURCEGROUP \
#	$ENVIRONMENTNAME

# deployApplicationAks \
#	$RESOURCEGROUP \
#	$ENVIRONMENTNAME