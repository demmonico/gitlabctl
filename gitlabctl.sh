#!/usr/bin/env bash

RC='\033[0;31m'
YC='\033[0;33m'
NC='\033[0m' # No Color

function __echo {
  local msg=$1
  echo -e " ${YC}>>>${NC} ${msg}"
}

function __error {
  local msg=$1
  echo -e " ${RC}>>> ${msg}${NC}"
}

# check for dependencies
for cmd in 'curl' 'jq' 'column'; do
  if ! command -v ${cmd} &> /dev/null; then
    __error "Command '${cmd}' could not be found"
    exit 1
  fi
done

if [ -z "${GITLAB_TOKEN}" ]; then
  __error "Missing personal Gitlab token as env variable [GITLAB_TOKEN]!!"
  exit 1
fi

CONFIG_FILE="config.json"
if [ ! -f "${CONFIG_FILE}" ]; then
  __error "Missing '${CONFIG_FILE}' file!"
  exit 1
fi

GITLAB_API_URL="$( jq -r '.gitlab_api_url' "${CONFIG_FILE}" )"
if [ -z "${GITLAB_API_URL}" ]; then
  __error "Missing Gitlab API URL as env variable [GITLAB_API_URL]!! E.g. 'https://gitlab.com/api/v4'"
  exit 1
fi

GROUP_IDS=($( jq -r '.gitlab_group_ids[] | .id' "${CONFIG_FILE}" ))
if [ -z "${GROUP_IDS}" ]; then
  __error "Missing Gitlab group IDs as env variable [GROUP_IDS]!! E.g. '(\"111\" \"222\")'"
  exit 1
fi

#-----------------------------------------------------------#

function curl_request() {
  resp="$( curl --silent -L --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" $@ )"
  if [[ $? == 0 ]]; then
    echo "${resp}"
  else
    __error "Ooops! Error: ${resp}"
    exit 10
  fi
}

function search_groups() {
  # TODO proper solution for pagination, currently fixed to page 1 and 100 per page
  local per_page=100
  local page=1

  local search="$1"
  local url="${GITLAB_API_URL}/groups?per_page=${per_page}&page=${page}"

  if [ -z "${search}" ]; then
    curl_request "${url}" | jq -r '.[]'
  else
    curl_request --get --data-urlencode "search=${search}" "${url}" | jq -r '.[]'
  fi
}

function list_all_groups() {
  search_groups | jq -r '[.id, .name] | @tsv'
}

function search_runners_by_group_id() {
  local group_id="$1"
  local status="${2:+"?status=${2}"}"
  curl_request "${GITLAB_API_URL}/groups/${group_id}/runners${status}" | jq -r '.[]'
}

function get_runner() {
  local id="$1"
  curl_request "${GITLAB_API_URL}/runners/${id}"
}

function delete_runner() {
  local runner_id="$1"
  curl_request --request DELETE "${GITLAB_API_URL}/runners/${runner_id}"
}

function search_jobs_by_runner_id() {
  local runner_id="$1"
  local status="${2:+"?status=${2}"}"
  curl_request "${GITLAB_API_URL}/runners/${runner_id}/jobs${status}" | jq -r '.[]'
}

#-----------------------------------------------------------#
# Groups and runners

function filter_only_nonshared_runners() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | jq 'select(.is_shared == false)'
}

function add_runners_description_info() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | \
    jq '.group_slug = (.description | sub(" - .*$"; ""))' | \
    jq '.env = (.description | sub(".* - "; "") | sub("/.*$"; ""))' | \
    jq '.ec2_instance = (.description | sub(".*@ i-"; "i-"))'
}

function get_all_nonshared_online_runners() {
  local runners=""
  for group_id in "${GROUP_IDS[@]}"; do
    runners+="$( \
      search_runners_by_group_id "${group_id}" "online" | \
        filter_only_nonshared_runners | \
        jq --arg groupId "${group_id}" '. += {"group_id": $groupId}' | \
        add_runners_description_info
    )"
  done

  local tags=""
  for runner_id in $( echo "${runners}" | jq -r '.id' ); do
    tags+="$( \
      get_runner "${runner_id}" | jq -r '{id: .id, tags: .tag_list}'
    )"
  done

  # Convert runners and tags to arrays
  runners_arr="$( echo "${runners}" | jq -s )"
  tags_arr="$( echo "${tags}" | jq -s )"

  # Merge runners and tags based on id
  echo "${runners_arr}" | \
    jq -r --argjson tags "${tags_arr}" 'map(. as $runner | $tags[] | select(.id == $runner.id) | $runner * .) | .[]'
}

function get_all_offline_runners() {
  local runners=""
  local runner_offline_statuses=("stale" "offline")

  for group_id in "${GROUP_IDS[@]}"; do
    runners+="$( \
      for status in "${runner_offline_statuses[@]}"; do
        search_runners_by_group_id "${group_id}" "${status}"| \
          filter_only_nonshared_runners
      done
    )"
  done

  echo "${runners}"
}

function group_runners_by_ip() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | jq -s 'group_by(.ip_address)'
}

function group_runners_by_group_id() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | jq -s 'group_by(.group_id)'
}

function filter_runners_by_instance() {
  local instance_pattern="$1"
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | \
    jq --arg instancePattern "${instance_pattern}" 'select((.ec2_instance | test($instancePattern)) or (.ip_address | test($instancePattern)))'
}

function filter_runners_by_group() {
  local group_pattern="$1"
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | \
    jq --arg groupPattern "${group_pattern}" 'select((.group_slug | test($groupPattern)) or (.group_id | test($groupPattern)))'
}

function get_runner_by_id() {
  local runner_id="$1"
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | \
    jq -c --arg runnerId "${runner_id}" 'select(.id == ($runnerId | tonumber)) | {id: .id, group_id: .group_id, ip_address: .ip_address, ec2_instance: .ec2_instance, env: .env, group_slug: .group_slug, status: .status}'
}

function print_runners_list() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done

  echo "${runners}" | \
    jq -r '[.id, .group_id, .ip_address, .ec2_instance, .env, .group_slug, .tags[]] | @tsv'
}

#-----------------------------------------------------------#
# Jobs

function search_jobs() {
  local runners=""
  while IFS= read -r line; do runners+="$line"; done
  local job_status_name="$1"

  local jobs=""
  while read -r runner_id; do
    runner_info="$( echo "${runners}" | get_runner_by_id "${runner_id}" )"
    jobs+="$( search_jobs_by_runner_id "${runner_id}" "${job_status_name}" | jq --argjson runnerInfo "${runner_info}" '. += {runner: $runnerInfo}' )"
  done < <(echo "${runners}" | jq -r '.id' | sort | uniq)
  echo "${jobs}"
}

function get_job_by_id() {
  local job_id="$1"
  local jobs=""
  while IFS= read -r line; do jobs+="$line"; done

  echo "${jobs}" | jq --arg jobId "${job_id}" 'select(.id == ($jobId | tonumber))'
}

function print_jobs_list() {
  local jobs=""
  while IFS= read -r line; do jobs+="$line"; done

  echo "${jobs}" | \
    jq -r '{id: .id, name: .name, project: .project.path_with_namespace, username: .user.username, web_url: .web_url, runner_id: .runner.id, runner_group: .runner.group_slug, runner_instance: .runner.ec2_instance, status: .status, finished_at: .finished_at}' | \
    jq -s 'sort_by(.finished_at)'
}


#-----------------------------------------------------------#

RUNNERS="$( get_all_nonshared_online_runners )"

# TODO search by tags
# TODO stats by instance & group

# input
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        # Usage: [--PARAM OPT_VALUE:<group_slug|group_id>]
        --runners-by-group) # List of the runners grouped by group_id. When value is present, filter by group_slug or group_id.
            # filter list if param is present
            if [ -n "$2" ]; then
              echo "${RUNNERS}" | filter_runners_by_group "$2" | \
                print_runners_list | column -t -s $'\t'
            # otherwise list all grouped by group_id
            else
              echo "${RUNNERS}" | group_runners_by_group_id | \
                jq -r '.[] | .[]' | print_runners_list | column -t -s $'\t'
            fi
            exit;;
        # Usage: [--PARAM OPT_VALUE:<ec2_instance|ip_address>]
        --runners-by-instance) # List of the runners grouped by instance. When value is present, filter by ec2_instance or ip_address.
            # filter list if param is present
            if [ -n "$2" ]; then
              echo "${RUNNERS}" | filter_runners_by_instance "$2" | \
                print_runners_list | column -t -s $'\t'
            # otherwise list all grouped by ip_address
            else
              echo "${RUNNERS}" | group_runners_by_ip | \
                jq -r '.[] | .[]' | print_runners_list | column -t -s $'\t'
            fi
            exit;;
        # TODO not always clean all runners, needs to run few times
        --remove-stale-runners) # Search for all stale/offline runners over provided groups and remove all of them
            offline_runners="$( echo "${RUNNERS}" | get_all_offline_runners )"
            __echo ""
            read -p "Do you want to remove '$( echo "${offline_runners}" | jq -s | jq 'length' )' stale/offline runners? (y/n): " answer
            if [ "$answer" == "y" ]; then
                __echo "Removing the runners..."
                for runner_id in $( echo "${offline_runners}" | jq -r '.id' ); do
                    delete_runner "${runner_id}" > /dev/null
                    echo -n "."
                done
                __echo "Done"
            else
                __error "Deletion has been aborted"
                exit 1
            fi
            exit;;
        # TODO add jobs list view
        # TODO add limit search by time, e.g. last 24h
        --jobs) # List of the jobs grouped by runner_id. When value is present, filter by job_id.
            # filter list if param is present
            if [ -n "$2" ]; then
              echo "${RUNNERS}" | search_jobs | get_job_by_id "$2"
            # otherwise list all grouped by ip_address
            else
              echo "${RUNNERS}" | search_jobs | \
                print_jobs_list | column -t -s $'\t'
            fi
            exit;;
        --running-jobs) # List of the running jobs grouped by runner_id. When value is present, filter by job_id.
            # filter list if param is present
            if [ -n "$2" ]; then
              echo "${RUNNERS}" | search_jobs "running" | get_job_by_id "$2"
            # otherwise list all grouped by ip_address
            else
              echo "${RUNNERS}" | search_jobs "running" | \
                print_jobs_list | column -t -s $'\t'
            fi
            exit;;
        --jobs-by-runner-id) # List of the jobs filtered by runner_id
            if [ -z "$2" ]; then __error "Error: param '${key}' needs a value!"; exit 1; fi
            echo "${RUNNERS}" | \
              jq -r --arg runnerId "$2" 'select(.id == ($runnerId | tonumber))' | \
              search_jobs | \
              print_jobs_list | column -t -s $'\t'
            exit;;
        --help) # Show help
            __echo "This is a script to manage GitLab runners. It can be used to list runners, jobs, remove stale runners, etc."
            __echo ""
            __echo "Usage: $0 [OPTIONS]"
            __echo ""
            awk '/--.*\) # .*/' "$0" | grep -v "awk '/--" | sed -e 's/)//g' -e 's/^\s*//g' -e 's/\s*#/\t/g' | column -t -s $'\t'
            __echo ""
            __echo "NOTE!!!"
            __echo "It required GROUP_IDS listed as an array, e.g. (\"111\" \"222\"), GITLAB_TOKEN and GITLAB_API_URL to be available as an env vars. Also it requires jq and column to be installed."
            __echo ""
            exit;;
        *)
            echo -e "${RC}Error:${NC} unknown param '${key}'!"
            exit 2;;
    esac
    shift
done
