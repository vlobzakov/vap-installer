#!/bin/bash

SUCCESS_CODE=0
FAIL_CODE=99
AUTHORIZATION_ERROR_CODE=701

BASE_DIR="$(pwd)"
RUN_LOG="$BASE_DIR/installer.log"

VAP_ENVS="$BASE_DIR/.vapenv"
OPENSTACK="/opt/jelastic-python311/bin/openstack"

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
  echo $subnets > subnets.json

  if [[ "x${FORMAT}" == "xjson" ]]; then
    output="{\"result\": 0, \"subnets\": ${subnets}}"
    echo $output
  else
    seperator=---------------------------------------------------------------------------------------------------
    rows="%-5s| %-20s| %-50s| %s\n"
    TableWidth=100
    echo "VHI Cluster Subnets"
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
      --vhi-proj-name=*)
      VHI_PROJ_NAME=${i#*=}
      shift
      shift
      ;;
      --vhi-username=*)
      VHI_USERNAME=${i#*=}
      shift
      shift
      ;;
      --vhi-password=*)
      VHI_PASSWORD=${i#*=}
      shift
      shift
      ;;
      --vhi-url=*)
      VHI_URL=${i#*=}
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

  echo "export OS_PROJECT_DOMAIN_NAME=${VHI_PROJ_NAME}" > ${VAP_ENVS};
  echo "export OS_USER_DOMAIN_NAME=${VHI_PROJ_NAME}" >> ${VAP_ENVS};
  echo "export OS_PROJECT_NAME=${VHI_PROJ_NAME}" >> ${VAP_ENVS};
  echo "export OS_USERNAME=${VHI_USERNAME}" >> ${VAP_ENVS};
  echo "export OS_PASSWORD=${VHI_PASSWORD}" >> ${VAP_ENVS};
  echo "export OS_AUTH_URL=${VHI_URL}" >> ${VAP_ENVS};
  echo "export OS_IDENTITY_API_VERSION=3" >> ${VAP_ENVS};
  echo "export OS_AUTH_TYPE=password" >> ${VAP_ENVS};
  echo "export OS_INSECURE=true" >> ${VAP_ENVS};
  echo "export NOVACLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export NEUTRONCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export CINDERCLIENT_INSECURE=true" >> ${VAP_ENVS};
  echo "export OS_PLACEMENT_API_VERSION=1.22" >> ${VAP_ENVS};
  echo "export VAP_STACK_NAME=${VAP_STACK_NAME}" >> ${VAP_ENVS};

  responseValidate

}



case ${1} in
    configure)
        configure "$@"
        ;;

    getSubnets)
      getSubnets
      ;;

    importProject)
      importProject "$@"
      ;;
esac

