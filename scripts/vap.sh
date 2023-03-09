#!/bin/bash

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701

BASE_DIR="$(pwd)"
RUN_LOG="$BASE_DIR/installer.log"

VAP_ENVS="$BASE_DIR/.vapenv"
OPENSTACK="/opt/jelastic-python311/bin/openstack"

MIN_INFRA_VCPU=8
MIN_INFRA_RAM=32000
MIN_USER_VCPU=12
MIN_USER_RAM=48000

trap "execResponse '${FAIL_CODE}' 'Please check the ${RUN_LOG} log file for details.'; exit 0" TERM
export TOP_PID=$$

log(){
  local message=$1
  local timestamp
  timestamp=`date "+%Y-%m-%d %H:%M:%S"`
  echo -e "[${timestamp}]: ${message}" >> ${RUN_LOG}
}

execResponse(){
  local result=$1
  local message=$2
  local output_json="{\"result\": ${result}, \"out\": \"${message}\"}"
  echo $output_json
}

execAction(){
  local action="$1"
  local message="$2"
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done";  } || {
    log "${message}...failed\n${stdout}\n";
    kill -s TERM $TOP_PID;
  }
}

execReturn(){
  local action="$1"
  local message="$2"
  source ${VAP_ENVS}
  stdout=$( { ${action}; } 2>&1 ) && { log "${message}...done";  } || { log "${message}...failed\n${stdout}\n"; }
  echo ${stdout}
}

getFlavors(){
  local cmd="${OPENSTACK} flavor list -f json"
  local output=$(execReturn "${cmd}" "Getting flavors list")
  echo $output > flavors.json
}

getFlavorsByParam(){
  local name="$1"
  local min_cpu="$2"
  local min_ram="$3"
  local title="$4"
  local id=0
  local flavors=$(cat flavors.json)
  local infra_flavors=$(jq -n '[]')
  for flavor in $(echo "${flavors}" | jq -r '.[] | @base64'); do
    _jq() {
     echo "${flavor}" | base64 --decode | jq -r "${1}"
    }
    RAM=$(_jq '.RAM')
    VCPUs=$(_jq '.VCPUs')

    [[ $RAM -ge $min_ram  && $VCPUs -ge $min_cpu  ]] && {

      id=$((id+1))
      Name=$(_jq '.Name')
      Ephemeral=$(_jq '.Ephemeral')

      infra_flavors=$(echo $infra_flavors | jq \
        --argjson id $id \
        --arg Name "$Name" \
        --arg RAM  $RAM \
        --arg VCPUs  $VCPUs \
        --arg Ephemeral  "$Ephemeral" \
      '. += [{"id": $id, "Name": $Name, "RAM": $RAM, "VCPUs": $VCPUs, "Ephemeral": $Ephemeral}]')
    }
  done

  local output="{\"result\": 0, \"${name}\": ${infra_flavors}}"
  echo $infra_flavors > ${name}.json

  if [[ "x${FORMAT}" == "xjson" ]]; then
    exit 0
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-20s| %-20s| %-20s| %s\n"
    TableWidth=100
    echo -e "\n\n${title}"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-20s| %-20s| %-20s| %s\n" ID Name RAM VCPUs Ephemeral
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${infra_flavors}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      RAM=$(_jq '.RAM')
      VCPUs=$(_jq '.VCPUs')
      Ephemeral=$(_jq '.Ephemeral')
      printf "$rows" "$id" "$Name" "$RAM" "$VCPUs" "$Ephemeral"
    done
  fi

}

getInfraFlavors(){
  getFlavorsByParam "infraFlavors" "${MIN_INFRA_VCPU}" "${MIN_INFRA_RAM}" "Infra node flavors"
}

getUserFlavors(){
  getFlavorsByParam "userFlavors" "${MIN_USER_VCPU}" "${MIN_USER_RAM}" "User node flavors"
}

getImages(){
  local id=0
  local images=$(jq -n '[]')
  local cmd="${OPENSTACK} image list -f json"
  local full_images=$(execReturn "${cmd}" "Getting images list")

  for row in $(echo "${full_images}" | jq -r '.[] | @base64'); do
    _jq() {
     echo "${row}" | base64 --decode | jq -r "${1}"
    }
    Name=$(_jq '.Name')

    grep -qE "^vap-[0-9]{2}-[0-9]_[0-9]{14}" <<< ${Name} && {
      id=$((id+1))
      Status=$(_jq '.Status')

      images=$(echo $images | jq \
        --argjson id "$id" \
        --arg Name "$Name" \
        --arg Status  "$Status" \
      '. += [{"id": $id, "Name": $Name, "Status": $Status}]')
    }
  done

  local output="{\"result\": 0, \"images\": ${images}}"
  echo $images > images.json

  if [[ "x${FORMAT}" == "xjson" ]]; then
    exit 0
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-50s| %s\n"
    TableWidth=100
    echo -e "\n\nVHI Images List"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-50s| %s\n" ID Name Status
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${images}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      Status=$(_jq '.Status')
      printf "$rows" "$id" "$Name" "$Status"
    done
  fi

}

getSubnets(){
  local id=0
  local subnets=$(jq -n '[]')
  source ${VAP_ENVS}
  for i in $(${OPENSTACK} network list -f value -c Name); do
    [[ "$(${OPENSTACK} network show $i -f value -c provider:network_type)" == "flat" ]] && {
      for subnet in $(${OPENSTACK} network show $i -f json -c subnets | jq -r .subnets[]); do
        cidr="$(${OPENSTACK} subnet show $subnet -f value -c cidr)"
        grep -qE "(^127\.)|(^10\.)|(^172\.1[6-9]\.)|(^172\.2[0-9]\.)|(^172\.3[0-1]\.)|(^192\.168\.)|(^169\.254)" <<< $cidr || {
          id=$((id+1))
          subnets=$(echo $subnets | jq \
            --argjson id "$id" \
            --arg Name "$i" \
            --arg Network "$subnet" \
            --arg Subnet "$cidr" \
          '. += [{"id": $id, "Name": $Name, "Network": $Network, "Subnet": $Subnet}]')
        }
      done
    }
  done

  local output="{\"result\": 0, \"subnets\": ${subnets}}"
  echo $subnets > subnets.json

  if [[ "x${FORMAT}" == "xjson" ]]; then
    exit 0
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-20s| %-50s| %s\n"
    TableWidth=100
    echo -e "\n\nVHI Cluster Subnets"
    printf "%.${TableWidth}s\n" "$seperator"
    printf "%-5s| %-20s| %-50s| %s\n" ID Name Network Subnet
    printf "%.${TableWidth}s\n" "$seperator"

    for row in $(echo "${subnets}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }
      id=$(_jq '.id')
      Name=$(_jq '.Name')
      Network=$(_jq '.Network')
      Subnet=$(_jq '.Subnet')
      printf "$rows" "$id" "$Name" "$Network" "$Subnet"
    done
  fi
}


responseValidate(){
#  source ${VAP_ENVS}
#  local resp=$(${OPENSTACK} stack show ${VAP_STACK_NAME})

  local cmd="${OPENSTACK} stack show ${VAP_STACK_NAME}"
  local output=$(execReturn "${cmd}" "Validation VHI")
  echo $output
}

configure(){
  for i in "$@"; do
    case $i in
      --project-domain=*)
      PROJECT_DOMAIN=${i#*=}
      shift
      shift
      ;;
      --user-domain=*)
      USER_DOMAIN=${i#*=}
      shift
      shift
      ;;
      --project=*)
      PROJECT=${i#*=}
      shift
      shift
      ;;
      --username=*)
      USERNAME=${i#*=}
      shift
      shift
      ;;
      --password=*)
      PASSWORD=${i#*=}
      shift
      shift
      ;;
      --url=*)
      URL=${i#*=}
      shift
      shift
      ;;
      --vap-stack-name=*)
      VAP_STACK_NAME=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done

  echo "export OS_PROJECT_DOMAIN_NAME=${PROJECT_DOMAIN}" > ${VAP_ENVS};
  echo "export OS_USER_DOMAIN_NAME=${USER_DOMAIN}" >> ${VAP_ENVS};
  echo "export OS_PROJECT_NAME=${PROJECT}" >> ${VAP_ENVS};
  echo "export OS_USERNAME=${USERNAME}" >> ${VAP_ENVS};
  echo "export OS_PASSWORD=${PASSWORD}" >> ${VAP_ENVS};
  echo "export OS_AUTH_URL=${URL}" >> ${VAP_ENVS};
  echo "export OS_IDENTITY_API_VERSION=3" >> ${VAP_ENVS};
  echo "export OS_AUTH_TYPE=password" >> ${VAP_ENVS};
  echo "export OS_INSECURE=true" >> ${VAP_ENVS};
  echo "export NOVACLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export NEUTRONCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export CINDERCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export OS_PLACEMENT_API_VERSION=1.22" >> ${VAP_ENVS};
  echo "export VAP_STACK_NAME=${VAP_STACK_NAME}" >> ${VAP_ENVS};

  getFlavors
  getInfraFlavors
  getUserFlavors
  getSubnets
  getImages

}

create(){
  for i in "$@"; do
    case $i in
      --image=*)
      IMAGE=${i#*=}
      shift
      shift
      ;;
      --user-host-count=*)
      USER_HOST_COUNT=${i#*=}
      shift
      shift
      ;;
      --subnet=*)
      SUBNET=${i#*=}
      shift
      shift
      ;;
      --user-flavor=*)
      USER_FLAVOR=${i#*=}
      shift
      shift
      ;;
      --infra-flavor=*)
      INFRA_FLAVOR=${i#*=}
      shift
      shift
      ;;
      --infra-root-size=*)
      INFRA_ROOT_SIZE=${i#*=}
      shift
      shift
      ;;
      --user-root-size=*)
      USER_ROOT_SIZE=${i#*=}
      shift
      shift
      ;;
      --infra-vz-size=*)
      INFRA_VZ_SIZE=${i#*=}
      shift
      shift
      ;;
      --user-vz-size=*)
      USER_VZ_SIZE=${i#*=}
      shift
      shift
      ;;
      *)
        ;;
    esac
  done

  _getValueById(){
    local id="$1"
    local arg="$2"
    local json_name="$3"
    local result=$(jq ".[] | select(.id == ${id}) | .${arg}" ${json_name} | tr -d '"')
    echo $result
  }

  IMAGE=$(_getValueById $IMAGE "Name" "images.json")
#  SUBNET=$(_getValueById $SUBNET "Name" "images.json")

  local createcmd="${OPENSTACK} stack create -t VAP.yaml"
  createcmd+=" --parameter 'image=${IMAGE}'"
  createcmd+=" --parameter 'user_hosts_count=${USER_HOST_COUNT}'"
  createcmd+=" --parameter 'public_network=public'"
  createcmd+=" --parameter 'public_subnet=${SUBNET}'"
  createcmd+=" --parameter 'infra_flavor=${INFRA_FLAVOR}'"
  createcmd+=" --parameter 'user_flavor=${USER_FLAVOR}'"
  createcmd+=" --parameter 'infra_root_volume_size=${INFRA_ROOT_SIZE}'"
  createcmd+=" --parameter 'user_root_volume_size=${USER_ROOT_SIZE}'"
  createcmd+=" --parameter 'infra_vz_volume_size=${INFRA_VZ_SIZE}'"
  createcmd+=" --parameter 'user_vz_volume_size=${USER_VZ_SIZE}'"
  createcmd+=" --parameter 'infra_swap_volume_size=8'"
  createcmd+=" --parameter 'user_swap_volume_size=8'"
  createcmd+=" --parameter 'key_name=vap-installer-demo'"
  createcmd+=" --wait"

  echo $createcmd

}

case ${1} in
    configure)
      configure "$@"
      ;;

    create)
      create "$@"
      ;;

    getSubnets)
      getSubnets
      ;;

    getInfraFlavors)
      getInfraFlavors
      ;;

    getUserFlavors)
      getUserFlavors
      ;;

    getImages)
      getImages
      ;;

esac
