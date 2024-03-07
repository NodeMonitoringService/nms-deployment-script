#!/usr/bin/env bash

### NMS Deployment Manager Script
###
### VERSION: 1.0
###
### DESCRIPTION: This script deploys a NMS monitoring environment on your local host.
###              A JSON configuration file is required to run the installation.
###              For more details, please refer to the NMS Docs: https://app.nodemonitoring.io/docs
###
### AUTHOR: NMS LLC
###
### OPTIONS:   -h | --help                          Display information header.
###            -d | --directory <path>              Provide an installation directory.
###                                                 Must be used in combination with --config
###            -c | --config <path>                 Provide the path of the JSON configuration file.
###                                                 Must be used in combination with --directory
###            -u | --update [-d <path> -c <path>]  Redeploy the stack with a new JSON configuration file.
###                                                 You must also provide the install directory and the JSON config path.

## Color variables
RED=`tput setaf 1`
GREEN=`tput setaf 2`
YELLOW=`tput setaf 3`
BLUE=`tput setaf 4`
MAGENTA=`tput setaf 5`
CYAN=`tput setaf 6`
RESET=`tput setaf 7`

## Variables
# read-only variables
readonly script_name=$(basename "$0")
readonly script_dir=$(dirname "$(realpath "$0")")
readonly log_file="/tmp/nms-install.log"
readonly repo_url="https://github.com/NodeMonitoringService/nms-deployment-files.git"
readonly docs_url="https://app.nodemonitoring.io/docs"
# container names
readonly node_exporter_container_name="nms-node-exporter"
readonly prometheus_container_name="nms-prometheus"
readonly promtail_container_name="nms-promtail"
readonly cadvisor_container_name="nms-cadvisor"
# init
install_dir=""
conf_file=""
tmp_dir=""
repo_dir=""
prometheus_retention_time=""
prometheus_port=""
node_exporter_port=""
promtail_port=""
cadvisor_port=""

## Functions
usage() {
    # Print script info header
    [ "$*" ] && echo "$0: $*"
    sed -n '/^###/,/^$/s/^### \{0,1\}//p' "$0"
    exit 0
} 2>/dev/null

log() {
    local logLevel="${1}"
    local message="${2}"
    local logToFile="${3:-false}"
    
    # Define message prefixes based on logLevel
    local prefix
    case "$logLevel" in
        "info")
            prefix="${GREEN}[INFO]${RESET}"
        ;;
        "warn")
            prefix="${YELLOW}[WARN]${RESET}"
        ;;
        "error")
            prefix="${RED}[ERROR]${RESET}"
        ;;
        *)
            prefix="[UNKNOWN]"
        ;;
    esac
    
    # Print to stderr for errors
    if [ "$logLevel" = "error" ]; then
        echo -e "$prefix $message" >&2
    else
        echo -e "$prefix $message"
    fi
    
    # Optionally log to file
    if [ "$logToFile" = true ]; then
        local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
        echo -e "[$timestamp] $prefix $message" | sed 's/\x1B\[[0-9;]\{1,\}[A-Za-z]//g' >> "$log_file"
    fi
}

die() {
    local level="${1}"
    local msg="${2}"
    local logToFile="${3:-false}"
    local code

    # Determine exit code based on log level
    if [ "$level" = "error" ]; then
        code=1
    else
        code=0
    fi

    # Use log function to output message
    log "$level" "$msg" "$logToFile"

    # Exit with the determined code
    exit "$code"
}


clean_up() {
    if [ -d "${tmp_dir}" ]; then
        rm -rf "${tmp_dir}" || {
            log "error" "Temp directory ${tmp_dir} could not be removed." true
        }
    fi
}

check_root() {
    if [ "$EUID" -eq 0 ];then
        log "warn" "You are running this script as root. This is not recommended." false
    fi
}

create_temp_directory() {
    tmp_dir="/tmp/${script_name}.$RANDOM.$$"
    (mkdir "${tmp_dir}") || {
        die "error" "Temp directory ${tmp_dir} could not be created." true
    }
    repo_dir="$tmp_dir/nms-deployment-files"
}

download_nms_repo() {
    log "info" "Additional files required for the deployment are available to download from GitHub ($repo_url)." false
    while true; do
        read -p "Do you want to proceed with the download? [Y/n]: " answer
        case $answer in
            [Yy]* )
                log "info" "Cloning repository into temp directory ${repo_dir}..." false
                git clone "${repo_url}" "${repo_dir}" || {
                die "error" "Could not clone the repository ${repo_url} to ${tmp_dir}" true
                }
                break
            ;;
            [Nn]* )
                die "info" "Download aborted." false
            ;;
            * )
                echo "Please answer yes or no."
            ;;
        esac
    done
}

validate_template_files() {    
    # Check for versions.env
    if [ ! -f "$script_dir/versions.env" ]; then
        die "error" "Missing versions.env file. Please ensure you have all the necessary files from the repository."
    fi
    
    # Define an array of required directories and their expected files
    declare -A required_structure=(
        ["$script_dir/config-templates/"]="cadvisor_conf_template.yml node_exporter_conf_template.yml prometheus_conf_template.yml promtail_conf_template.yml"
        ["$script_dir/docker-compose-templates/"]="cadvisor_compose_template.yml node_exporter_compose_template.yml prometheus_compose_template.yml promtail_compose_template.yml"
        ["$script_dir/scripts/"]="nms-service-restart.sh nms-service-upgrade.sh"
    )
    
    # Loop through the required_structure to check each directory and file
    for dir in "${!required_structure[@]}"; do
        if [ ! -d "$dir" ]; then
            die "error" "Missing directory: $dir. Please ensure you have all the necessary directories from the repository."
        else
            # Split the string of filenames into an array
            IFS=' ' read -r -a files <<< "${required_structure[$dir]}"
            for file in "${files[@]}"; do
                if [ ! -f "$dir$file" ]; then
                    die "error" "Missing file: $dir$file. Please ensure you have all the necessary files from the repository."
                fi
            done
        fi
    done    
}

check_requirements() {
    local -a missing_requirements=()
    local -ra commands=("docker" "docker-compose" "jq" "sed" "git")
    
    for cmd in "${commands[@]}"; do
        if [ ! -x "$(command -v $cmd)" ]; then
            missing_requirements+=("$cmd")
        fi
    done
    
    if [ ${#missing_requirements[@]} -ne 0 ]; then
        die "error" "Missing requirement(s) for deployment: ${missing_requirements[*]}. Please follow the documentation at ${docs_url}" true
    fi
}

create_directory_structure() {
    local nms_dir="${1}"
    
    mkdir -p "${nms_dir}/docker-compose" \
    "${nms_dir}/configs" \
    "${nms_dir}/data/prometheus" \
    "${nms_dir}/data/promtail" \
    "${nms_dir}/scripts" || {
        die "error" "Could not create directory structure under ${nms_dir}" true
    }
}

validate_nms_directory() {
    local base_dir="${1}"
    
    # List of expected child directories
    local expected_dirs=(
        "docker-compose"
        "configs"
        "data"
        "scripts"
    )
    
    # Loop through each expected directory and check if it exists
    for dir in "${expected_dirs[@]}"; do
        if [[ ! -d "${base_dir}/${dir}" ]]; then
            # a directory does not exist
            return 1
        fi
    done
    # all directories exist
    return 0
}

nms_directory_exists() {
    local dir="${1}"
    check=$(ls $dir | grep nms$)
    if [ -n "${check}" ]; then
        return 0
    else
        return 1
    fi
}

delete_nms_subdir_contents() {
    local base_dir="${1}"
    local subdirs=("docker-compose" "configs" "scripts")

    for subdir in "${subdirs[@]}"; do
        local target_dir="${base_dir}/${subdir}"
        if [ -d "${target_dir}" ]; then
            (rm -rf "${target_dir:?}"/*) || {
                die "error" "Failed to delete content of $target_dir" true
            }
        fi
    done
}

containers_are_running() {
    local -a running_containers=()
    declare -A arr
    arr=([exporter_name]=$node_exporter_container_name [prometheus_name]=$prometheus_container_name [promtail_name]=$promtail_container_name [cadvisor_name]=$cadvisor_container_name)
    
    for name in "${!arr[@]}"; do
        check=$(docker ps --filter name="${arr[$name]}" | grep -w "${arr[$name]}")
        if [ -n "${check}" ]; then
            running_containers+=("${arr[$name]}")
        fi
    done
    
    if [ ${#running_containers[@]} -ne 0 ]; then
        return 0
    else
        return 1
    fi
}

validate_json() {
    if jq . ${1} >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

fetch_and_validate() {
    local json_content="${1}"
    local jq_filter="${2}"
    
    local value=$(echo "$json_content" | jq -r "$jq_filter")
    if [[ -z "${value}" ]]; then
        die "error" "Missing value for ${jq_filter} in config JSON" true
    fi
    echo "$value"
}

fetch_configuration_values() {
    
    local config_json="${1}"
    local json_content=$(cat $config_json)
    
    # Hostname
    nms_host_label=$(fetch_and_validate "$json_content" ".hostname")
    
    # Connection Config
    connection_filter=".connection_config"
    nms_metrics_url=$(fetch_and_validate "$json_content" "${connection_filter}.metricsUrl")
    nms_logs_url=$(fetch_and_validate "$json_content" "${connection_filter}.logsUrl")
    nms_api_endpoint=$(fetch_and_validate "$json_content" "${connection_filter}.orgName")
    nms_api_username=$(fetch_and_validate "$json_content" "${connection_filter}.apiUser")
    nms_api_password=$(fetch_and_validate "$json_content" "${connection_filter}.apiPassword")
    
    # Stack Config
    stack_filter=".stack_config"
    prometheus_install=$(jq -r '.stack_config[] | select(.name == "Prometheus") | .name' "$config_json" | grep -q . && echo "true" || echo "false")
    exporter_install=$(jq -r '.stack_config[] | select(.name == "Node Exporter") | .name' "$config_json" | grep -q . && echo "true" || echo "false")
    promtail_install=$(jq -r '.stack_config[] | select(.name == "Promtail") | .name' "$config_json" | grep -q . && echo "true" || echo "false")
    cadvisor_install=$(jq -r '.stack_config[] | select(.name == "cAdvisor") | .name' "$config_json" | grep -q . && echo "true" || echo "false")
    
    # Container Ports
    if $prometheus_install; then
        prometheus_port=$(jq -r '.stack_config[] | select(.name == "Prometheus") | .port' "$config_json")
        prometheus_retention_time=$(jq -r '.stack_config[] | select(.name == "Prometheus") | .logRetentionTime' "$config_json")
    fi

    if $exporter_install; then
        node_exporter_port=$(jq -r '.stack_config[] | select(.name == "Node Exporter") | .port' "$config_json")
    fi

    if $promtail_install; then
        promtail_port=$(jq -r '.stack_config[] | select(.name == "Promtail") | .port' "$config_json")
    fi

    if $cadvisor_install; then
        cadvisor_port=$(jq -r '.stack_config[] | select(.name == "cAdvisor") | .port' "$config_json")
    fi   
    
}

substitute_and_check() {
    local file_path="${1}"
    local placeholder="${2}"
    local replace_with="${3}"
    
    sed -i "s|${placeholder}|${replace_with}|g" "${file_path}" || {
        die "error" "Could not perform substitution: ${placeholder} in ${file_path}" true
    }
}

deploy_docker_compose_component() {
    local nms_dir="${1}"
    local component_name="${2}"
    
    # Derive file name, replace name, and replace port from component name
    local file_name="${component_name}_compose_template.yml"
    local replace_name="NMS_$(echo ${component_name} | tr '-' '_' | tr '[:lower:]' '[:upper:]')_NAME"
    local replace_port="NMS_$(echo ${component_name} | tr '-' '_' | tr '[:lower:]' '[:upper:]')_PORT"
    local replace_path="NMS_INSTALL_PATH"
    
    # Derive the replacement name and port values
    local replace_name_with="${component_name}_container_name"
    local replace_port_with="${component_name}_port"
    local replace_path_with=${nms_dir}
    
    # Path to the template file in the temporary directory
    local file_path="${repo_dir}/docker-compose-templates/${file_name}"
    
    # Perform substitutions on the cloned file
    substitute_and_check "${file_path}" "${replace_name}" "${!replace_name_with}"
    substitute_and_check "${file_path}" "${replace_port}" "${!replace_port_with}"
    substitute_and_check "${file_path}" "${replace_path}" "${replace_path_with}"
    
    # Move the processed file to the required location
    mv "${file_path}" "${nms_dir}/docker-compose/${component_name}.yml" || {
        die "error" "Could not move ${file_name} to ${nms_dir}/docker-compose" true
    }
}

deploy_config() {
    local nms_dir="${1}"
    local config_name="${2}"
    local file_path="${repo_dir}/config-templates/${config_name}_conf_template.yml"
    
    # Substitution mapping
    local substitutions=(
        "NMS_HOST_LABEL:${nms_host_label}"
        "NMS_METRICS_URL:${nms_metrics_url}"
        "NMS_LOGS_URL:${nms_logs_url}"
        "NMS_API_ENDPOINT:${nms_api_endpoint}"
        "NMS_API_USERNAME:${nms_api_username}"
        "NMS_API_PASSWORD:${nms_api_password}"
        "NMS_PROMETHEUS_PORT:${prometheus_port}"
        "NMS_PROMTAIL_PORT:${promtail_port}"
        "NMS_NODE_EXPORTER_PORT:${node_exporter_port}"
        "NMS_CADVISOR_PORT:${cadvisor_port}"
    )
    
    for substitution in "${substitutions[@]}"; do
        IFS=":" read -r placeholder replace_with <<< "${substitution}"
        # Only substitute if the placeholder is present in the file.
        if grep -q "${placeholder}" "${file_path}"; then
            substitute_and_check "${file_path}" "${placeholder}" "${replace_with}"
        fi
    done
    
    # Move the processed file to the required location
    mv "${file_path}" "${nms_dir}/configs/${config_name}.yml" || {
        die "error" "Could not move ${config_name}.yml to ${nms_dir}/configs" true
    }
}

append_prometheus_config() {
    local nms_dir="${1}"
    local name="${2}"
    local port="${3}"
    local prometheus_config="${nms_dir}/configs/prometheus.yml"
    
    echo " - job_name: '${name}'" >> "${prometheus_config}"
    echo "   static_configs:" >> "${prometheus_config}"
    echo "     - targets: ['localhost:${port}']" >> "${prometheus_config}"
    echo "   scheme: http" >> "${prometheus_config}"
}

append_prometheus_services() {
    local nms_dir="${1}"
    local config_json="${2}"
    local prometheus_config="${nms_dir}/configs/prometheus.yml"
    local json_content=$(cat "$config_json")
    
    echo "$json_content" | jq -c '.service_config[]' | while IFS= read -r service; do
        service_job=$(echo "$service" | jq -r '.serviceName')
        service_label=$(echo "$service" | jq -r '.label')
        service_ip=$(echo "$service" | jq -r '.ip')
        service_port=$(echo "$service" | jq -r '.port')
        service_path=$(echo "$service" | jq -r '.path')
        service_scheme=$(echo "$service" | jq -r '.protocol')
        service_network=$(echo "$service" | jq -r '.network')
        
        # Appending the results using echo and redirect append operator
        echo " - job_name: '${service_job}'" >> "${prometheus_config}"
        echo "   static_configs:" >> "${prometheus_config}"
        echo "     - targets: ['${service_ip}:${service_port}']" >> "${prometheus_config}"
        echo "       labels:" >> "${prometheus_config}"
        echo "         service: '${service_label}'" >> "${prometheus_config}"
        if [ "${service_label}" = "rpc-node" ]; then
            echo "         network: '${service_network}'" >> "${prometheus_config}"
        fi
        echo "   metrics_path: ${service_path}" >> "${prometheus_config}"
        echo "   scheme: ${service_scheme}" >> "${prometheus_config}"
    done
}

deploy_new_stack_option() {
    if [ "$#" -gt 0 ]; then
        local passed_dir="${1}"
        local passed_json="${2}"
    else
        local passed_dir=""
        local passed_json=""
    fi
    
    # check requirements for script and deployment
    check_requirements

    # create temporary directory and download the repository
    create_temp_directory
    download_nms_repo
    
    # Check for running NMS containers
    if containers_are_running; then
        die "error" "NMS container(s) already exist" false
    fi
    
    if [ ! -z "$passed_dir" ]; then
        install_dir=$passed_dir
    else
        install_dir=$HOME
    fi
    
    if ! nms_directory_exists $install_dir; then
        nms_dir="${install_dir}/nms"
    else
        die "error" "An existing NMS directory has been detected at $install_dir/nms/. Please use the 'Deploy new configuration' option if you want to update your configuration." true
    fi
    
    if [ ! -z "$passed_json" ]; then
        conf_file=$passed_json
    else
        conf_file="$HOME/nms-config.json"
    fi
    
    if ! validate_json $conf_file; then
        die "error" "Provided file $conf_file doesn't exist or is not a valid JSON file" true
    fi
    
    echo "Deploying NMS to $nms_dir using $conf_file"
    
    while true; do
        read -p "Do you want to continue? [Y/n]: " answer
        case $answer in
            [Yy]* )
                install_nms $nms_dir $conf_file
                break
            ;;
            [Nn]* )
                die "info" "Installation aborted" false
            ;;
            * )
            echo "Please answer yes or no.";;
        esac
    done
}

install_nms() {
    local install_dir="${1}"
    local install_json="${2}"
    
    # fetch values from JSON file
    fetch_configuration_values $install_json
    
    # create NMS directories
    create_directory_structure $install_dir
    
    # versions .env file
    cp "${repo_dir}/versions.env" "${install_dir}/docker-compose/.env" || {
        die "error" "Could not copy versions.env to ${install_dir}/docker-compose/.env" true
    }
    
    # Prometheus deployment
    if [[ "${prometheus_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "prometheus"
        deploy_config $install_dir "prometheus"
    fi
    
    # Promtail deployment
    if [[ "${promtail_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "promtail"
        deploy_config $install_dir "promtail"
    fi
    
    # Node-Exporter deployment
    if [[ "${exporter_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "node_exporter"
        if [[ "${prometheus_install}" = "true" ]]; then
            append_prometheus_config $install_dir "node_exporter" "${node_exporter_port}"
        fi
    fi
    
    # cAdvisor deployment
    if [[ "${cadvisor_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "cadvisor"
        if [[ "${prometheus_install}" = "true" ]]; then
            append_prometheus_config $install_dir "cadvisor" "${cadvisor_port}"
        fi
    fi

    # Prometheus Services
    if [[ "${prometheus_install}" = "true" ]]; then
        append_prometheus_services $install_dir $install_json
    fi
    
    # Scripts
    cp "${repo_dir}/scripts/"* "${install_dir}/scripts/" || {
        die "error" "Failed to copy scripts to ${install_dir}/scripts/. Check permissions and available disk space." true
    }
    
    # set permissions to the deployed files
    local paths=(
        "${install_dir}/docker-compose"
        "${install_dir}/configs"
        "${install_dir}/scripts"
    )
    
    for path in "${paths[@]}"; do
        chown -R $USER:$USER "$path"
        chmod -R 700 "$path"
    done

    # start the containers
    bash "${install_dir}/scripts/nms-service-restart.sh" -a || {
        die "error" "Failed to start containers." true
    }

    die "info" "NMS deployment was successful! You can now visit https://dashboards.nodemonitoring.io to check out the stats." false
}

apply_new_config_option () {
    if [ "$#" -gt 0 ]; then
        local passed_dir="${1}"
        local passed_json="${2}"
    else
        local passed_dir=""
        local passed_json=""
    fi
    
    # check requirements for script and deployment
    check_requirements

    # create temporary directory and download the repository
    create_temp_directory
    download_nms_repo
    
    # Check for running NMS containers
    if ! containers_are_running; then
        die "error" "No running NMS docker containers found on this host" false
    fi
    
    if [ ! -z "$passed_dir" ]; then
        install_dir=$passed_dir
    else
        install_dir=$HOME/nms
    fi
    
    if [ ! -z "$passed_json" ]; then
        conf_file=$passed_json
    else
        conf_file="$HOME/nms-config.json"
    fi
    
    if ! validate_nms_directory $install_dir; then
        die "error" "No existing NMS directory has been detected at $install_dir" true
    fi
    
    if ! validate_json $conf_file; then
        die "error" "Provided file $conf_file doesn't exist or is not a valid JSON file" true
    fi
    
    echo "Updating NMS installation at $install_dir using $conf_file"
    
    while true; do
        read -p "Do you want to continue? [Y/n]: " answer
        case $answer in
            [Yy]* )
                redeploy_files $install_dir $conf_file
                break
            ;;
            [Nn]* )
                die "info" "Configuration update aborted" false
            ;;
            * )
                echo "Please answer yes or no."
            ;;
        esac
    done
}

redeploy_files() {
    local install_dir="${1}"
    local install_json="${2}"
    
    # fetch values from JSON file
    fetch_configuration_values $install_json
    
    # Remove existing configuration files
    delete_nms_subdir_contents $install_dir
    
    # versions .env file
    mv "${repo_dir}/versions.env" "${install_dir}/docker-compose/.env" || {
        die "error" "Could not move versions.env to ${install_dir}/docker-compose/.env" true
    }
    
    # Prometheus
    if [[ "${prometheus_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "prometheus"
        deploy_config $install_dir "prometheus"
    fi
    
    # Loki
    if [[ "${promtail_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "promtail"
        deploy_config $install_dir "promtail"
    fi
    
    # Node Exporter
    if [[ "${exporter_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "node_exporter"
        if [[ "${prometheus_install}" = "true" ]]; then
            append_prometheus_config $install_dir "node_exporter" "${node_exporter_port}"
        fi
    fi
    
    # cAdvisor
    if [[ "${cadvisor_install}" = "true" ]]; then
        deploy_docker_compose_component $install_dir "cadvisor"
        if [[ "${prometheus_install}" = "true" ]]; then
            append_prometheus_config $install_dir "cadvisor" "${cadvisor_port}"
        fi
    fi

    # Prometheus Services
    if [[ "${prometheus_install}" = "true" ]]; then
        append_prometheus_services $install_dir $install_json
    fi
    
    # Scripts
    cp "${repo_dir}/scripts/"* "${install_dir}/scripts/" || {
        die "error" "Failed to copy scripts to ${install_dir}/scripts/. Check permissions and available disk space." true
    }
    
    # set permissions to the deployed files
    local paths=(
        "${install_dir}/docker-compose"
        "${install_dir}/configs"
        "${install_dir}/scripts"
    )
    
    for path in "${paths[@]}"; do
        chown -R $USER:$USER "$path"
        chmod -R 700 "$path"
    done

    # Restart all containers
    bash "$install_dir/scripts/nms-service-restart.sh" -a || {
        die "error" "Failed to execute container restart script" true
    }

    log "info" "New configuration was applied successfully! You can now visit https://dashboards.nodemonitoring.io to check out the stats." false
    exit 0
}

uninstall_nms_option () {
    if [ "$#" -gt 0 ]; then
        local passed_dir="${1}"
    else
        local passed_dir=""
    fi
    
    # check requirements for script and deployment
    check_requirements

    log "info" "Preparing for uninstallation..." false
    
    # Check for running NMS containers
    if ! containers_are_running; then
        die "error" "No running NMS docker containers found on this host" false
    fi
    
    if [ ! -z "$passed_dir" ]; then
        install_dir=$passed_dir
    else
        install_dir=$HOME/nms
    fi
        
    if ! validate_nms_directory $install_dir; then
        die "error" "No existing NMS directory has been detected at $install_dir" true
    fi
        
    
    log "info" "This process will stop all NMS containers and delete the NMS directory ($install_dir)" false
    
    while true; do
        read -p "Do you want to continue? [Y/n]: " answer
        case $answer in
            [Yy]* )
                uninstall_nms $install_dir
                break
            ;;
            [Nn]* )
                die "info" "Uninstallation aborted" false
            ;;
            * )
                echo "Please answer yes or no."
            ;;
        esac
    done
}

uninstall_nms() {
    local dir="${1}"
    
    # Ensure that the directory exists and contains scripts/nms-service-restart.sh   
    if [[ ! -f "$dir/scripts/nms-service-restart.sh" ]]; then
        die "error" "Invalid directory provided or essential script not found" true
    fi
    
    # Stop all containers
    bash "$dir/scripts/nms-service-restart.sh" -s -a || {
        die "error" "Failed to execute container shutdown script" true
    }
    
    # Remove the directory
    rm -r "$dir" || {
        die "error" "Failed to remove the installation directory ${dir}" true
    }

    die "info" "Successfully uninstalled NMS" false
}

main_menu() {
    while true; do
        echo "Choose one of the following options:"
        echo ""
        echo "[1] Deploy NMS"
        echo "[2] Apply new configuration"
        echo "[3] Uninstall NMS"
        echo "[4] Exit"
        echo ""
        read -p "Enter your choice [1-4]: " choice
        
        case $choice in
            1)
                deploy_new_stack_option
            ;;
            2)
                apply_new_config_option
            ;;
            3)
                uninstall_nms_option
            ;;
            4)
                die "info" "Exiting." false
            ;;
            *)
                log "error" "Invalid option." false
            ;;
        esac
    done
}

main() {
    check_root
    echo "${CYAN}NMS Host Deployment${RESET}"
    echo ""
    main_menu
}

## Parse Options
parse_user_options() {
    local -r args=("${@}")
    local opts
    
    opts=$(getopt --options hud:c: --long help,update,directory:,config: -- "${args[@]}" 2> /dev/null) || {
        die "error" "Error parsing options" false
    }
    
    eval set -- "${opts}"
    
    local opts_set=false
    local update_mode=false
    while true; do
        case "${1}" in
            --help|-h)
                usage
                exit 0
            ;;
            --update|-u)
                opts_set=true
                update_mode=true
                shift
            ;;
            --directory|-d)
                opts_set=true
                install_dir="${2}"
                shift 2
            ;;
            --config|-c)
                opts_set=true
                conf_file="${2}"
                shift 2
            ;;
            --)
                shift
                break
            ;;
            *)
                break
            ;;
        esac
    done
    
    # Check the provided combinations and act accordingly
    if $opts_set; then
        if $update_mode; then
            if [ -z "$install_dir" ] && [ -z "$conf_file" ]; then
                die "error" "The --update flag requires both --directory and --config to be provided." 1
                elif [ -z "$install_dir" ] || [ -z "$conf_file" ]; then
                die "error" "Missing either --directory or --config when using --update." 1
            else
                apply_new_config_option $install_dir $conf_file
            fi
        else
            if [ -z "$install_dir" ] || [ -z "$conf_file" ]; then
                die "error" "Both --directory and --config need to be provided." 1
            else
                deploy_new_stack_option $install_dir $conf_file
            fi
        fi
    fi
}

## Script

# Exit on error
set -o errexit
# Exit on empty variables
set -o nounset
# Return the highest exitcode in pipeline
set -o pipefail

# Cleanup on exits
trap clean_up ERR EXIT SIGINT SIGTERM

# Parse user options
parse_user_options "${@}"

# Execute main function
main
