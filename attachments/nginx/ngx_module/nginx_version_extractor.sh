#!/bin/bash

initializeEnviroment()
{
    CURRENT_TIME=""
    PACKAGE_VERSION=""
    CUR_NGINX_ALREADY_SUPPORTED=false
    NUMBER_OF_CONFIGURATION_FLAGS=0
    TMP_NGINX_UNPARSED_CONFIGURATION="/tmp/nginx_unparsed_tmp_conf.txt"
    TMP_NGINX_PARSED_CONFIGURATION_FLAGS="/tmp/nginx_parsed_conf_flags.txt"
    TMP_DECODED_FILE_PATH="/tmp/decoded_file.txt"
    IS_ALPINE=false
    if [ ! -z "$(cat /etc/*release | grep alpine)" ]; then
        IS_ALPINE=true
    fi    
}

usage()
{
    local IS_ERROR=$1
    local option=$2
    if [[ ${IS_ERROR} == true ]]; then
        echo "Error: unsupported option '${option}'"
    fi
    
    echo "Usage:"
    line_padding="               "
    local debug_print_option="-h, --help"
    printf "%s %s Print (this) help message\n" "$debug_print_option" "${line_padding:${#debug_print_option}}"
    debug_print_option="-d, --debug"
    printf "%s %s Enable debug mode\n" "$debug_print_option" "${line_padding:${#debug_print_option}}"
    debug_print_option="-v, --verbose"
    printf "%s %s show version and configure options\n" "$debug_print_option" "${line_padding:${#debug_print_option}}"
    debug_print_option="-o, --output"
    printf "%s %s change output file name into '${option}'\n" "$debug_print_option" "${line_padding:${#debug_print_option}}"
    debug_print_option="-f, --force"
    printf "%s %s force creation of makefile'\n" "$debug_print_option" "${line_padding:${#debug_print_option}}"

    if [[ ${IS_ERROR} == true ]]; then
        exit -1
    else 
        exit 1
    fi
}

debug()
{
    local debug_message=$1
    if [[ $IS_DEBUG_MODE_ACTIVE == true ]]; then
        echo -e $debug_message
    fi
}

check_flags_options()
{
    local argc=$#
    
    for (( i = 1; i <= $argc; i++ )); do
        local option=${!i}
        local IS_ERROR=false
        if [[ "$option" == "--debug" || "$option" == "-d" ]]; then
            IS_DEBUG_MODE_ACTIVE=true
        elif [[ "$option" == "--verbose" || "$option" == "-v" ]]; then
            IS_VERBOSE_MODE_ACTIVE=true 
        elif [[ "$option" == "--force" || "$option" == "-f" ]]; then
            IS_FORCE_OUTPUT=true 
        elif [[ "$option" == "--output" || "$option" == "-o" ]]; then
            IS_OUTPUT_NAME_MODE_ACTIVE=true 
            i=$((i+1))
            FILE_NAME=${!i}   
            if [[ -z ${FILE_NAME} ]]; then
                echo "Error: No file name was given for ${option} option."
                exit -1
            fi 
		elif [[ "$option" == "--input" || "$option" == "-i" ]]; then
			i=$((i+1))
			if [[ -z ${!i} ]]; then
                echo "Error: No file name was given for ${option} option."
                exit -1
            fi 
			cp -f ${!i} ${TMP_NGINX_UNPARSED_CONFIGURATION}
			IS_INPUT_NAME_MODE_ACTIVE=true
        elif [[ "$option" == "--help" || "$option" == "-h" ]]; then
            usage ${IS_ERROR} ${option} 
        elif [[ ! -z $option ]]; then
            IS_ERROR=true
            usage ${IS_ERROR} ${option} 
        fi
    done
}

_main()
{
    echo "Starting verification of Check Point support with local nginx server"
    initializeEnviroment
    
	if [[ ${IS_INPUT_NAME_MODE_ACTIVE} != true ]]; then
		nginx -V &> "$TMP_NGINX_UNPARSED_CONFIGURATION"
	fi
	getNginxVersion
    
    if [[ $IS_VERBOSE_MODE_ACTIVE == true ]]; then 
    echo ""
        cat ${TMP_NGINX_UNPARSED_CONFIGURATION}
    echo ""
    fi
    
    while IFS= read -ra UNPARSED_CONFIGURATION_LINE <&3; do
        if [[ ${UNPARSED_CONFIGURATION_LINE} =~ ^"nginx version:" ]]; then
            openFile
        elif [[ ${UNPARSED_CONFIGURATION_LINE} =~ ^"built by gcc" ]]; then
            addBuiltConfiguration "${UNPARSED_CONFIGURATION_LINE}"
        elif [[ ${UNPARSED_CONFIGURATION_LINE} =~ ^"configure arguments:" ]]; then
            IFS="'"
            addAndCutOptionalFlags ${UNPARSED_CONFIGURATION_LINE}
            IFS=" "
            addRequiredFlags ${CONFIGURATION_FLAGES_NEED_TO_BE_PARSED}
        fi
    done 3<"$TMP_NGINX_UNPARSED_CONFIGURATION"
      
    PARSED_CONFIGURATION="CONFIGURE_OPT=\"${COMBINED_CONFIGURATION_FLAGS}\"\n\n"
    NUMBER_OF_CONFIGURATION_FLAGS=$((NUMBER_OF_CONFIGURATION_FLAGS-1))
    local local_pwd=$(pwd)
    if [[ ${local_pwd:0:2} == "//" ]]; then
        local_pwd=${local_pwd:1}
    fi
    debug "Moving parsed configuration to target ${local_pwd}/${FILE_NAME} configuration file"
    echo -e ${PARSED_CONFIGURATION} > ${FILE_NAME}
    echo -e ${CC_OPTIONAL_FLAGS} >> ${FILE_NAME}
    add_nginx_and_release_versions
    if [[ $CUR_NGINX_ALREADY_SUPPORTED == true ]]; then 
        tearDown
        echo -e "Check Point Nano Agent already supported on this environment"
    else 
        tearDown
        echo -e "Extracted environment data to $(pwd)/${FILE_NAME} \nPlease send file to nano-agent-attachments-support@checkpoint.com"
    fi
}

tearDown()
{
    rm -f ${TMP_NGINX_UNPARSED_CONFIGURATION}
    rm -f ${TMP_NGINX_PARSED_CONFIGURATION_FLAGS}
    rm -f ${TMP_DECODED_FILE_PATH}
    rm -f ${TMP_NGINX_VERSION_FILE}
}

getNginxVersion()
{    
    TMP_NGINX_VERSION_FILE="/tmp/nginx_version_file.txt"
    cat ${TMP_NGINX_UNPARSED_CONFIGURATION} | grep "nginx version:" &> "$TMP_NGINX_VERSION_FILE"
    if [[ $IS_ALPINE == true ]]; then
        NGINX_VERSION=`cat ${TMP_NGINX_VERSION_FILE} | grep -oE [0-9]+.[0-9]+.[0-9]+`
    else
        NGINX_VERSION=`cat ${TMP_NGINX_VERSION_FILE} | grep -oP [0-9]+.[0-9]+.[0-9]+`
    fi
}

openFile()
{
    if [[ ${IS_OUTPUT_NAME_MODE_ACTIVE} != true ]]; then
        FILE_NAME="${NGINX_VERSION}.mk"
        debug "Trying to create an empty ${NGINX_VERSION} file"
        FILE_NAME_PATH="$(pwd)/${FILE_NAME}"
    
        if [[ -z ${FILE_NAME_PATH} || ! ( ${FILE_NAME} =~ [0-9]+.[0-9]+.[0-9]+.mk ) ]]; then
            echo "ERROR: can't find nginx version."
            exit -1
        fi
        
        if [[ -f "${FILE_NAME_PATH}" ]]; then
            echo "The output file: ${FILE_NAME} already exists. Do you want to overwrite this file? [y/N]"
            read answer 
            if [[ ${answer} != "y" ]]; then
                echo -e "Stopping after the operation was cancelled.\nIf you wish to use other output file name you can use option -o or --output"
                exit -1
            fi
        fi
    else 
        debug "Trying to create an empty ${FILE_NAME} file"
        FILE_NAME_PATH="${FILE_NAME}"
    fi
    
    touch ${FILE_NAME_PATH} &> /dev/null
    if [ ! -e ${FILE_NAME_PATH} ];then
        echo "Failed to create ${FILE_NAME_PATH}"
        exit -1
    fi
    debug "Created an empty ${FILE_NAME} file"
}
           
checkAllDBLineFlags()
{
    local argc=$#
    local argv=("$@")
    local number_of_db_line_flags=$((argc-3))
    local gcc_version_prefix="--with-cc="
    
    if [[ ${number_of_db_line_flags} == ${NUMBER_OF_CONFIGURATION_FLAGS} ]]; then       
        for ((i = 3; i < ${argc}; i++)); do
            if [[ ${argv[i]} =~ ^"${gcc_version_prefix}"* ]]; then
                continue
            fi
            checkFlag ${argv[i]}  
            if [[ ${found_equal_flag} == false ]]; then
                EQUAL_FLAGS=false
                return
            fi  
        done        
    else return
    fi
    
    EQUAL_FLAGS=true      
}

checkFlag()
{
    found_equal_flag=false
    db_flag=$1
    while IFS='\' read -ra flag; do
        if [[ "${flag}" == "${db_flag}" ]] || [[ "${flag} " == "${db_flag}" ]]; then
            found_equal_flag=true
            break
        fi
    done < ${TMP_NGINX_PARSED_CONFIGURATION_FLAGS}
}

addBuiltConfiguration()
{
    BUILT_BY_GCC_FLAG_PREFIX="--with-cc=/usr/bin/"
    if [[ $IS_ALPINE == true ]]; then
        GCC_VERSION=`echo "$1" | grep -oE "gcc "[0-9]+ | tr ' ' '-'`
    else
        GCC_VERSION=`echo "$1" | grep -oP "gcc "[0-9]+ | tr ' ' '-'`
    fi
    if [[ "$GCC_VERSION" == "gcc-4" ]]; then 
        GCC_VERSION=gcc-5
    elif [[ "$GCC_VERSION" == "gcc-10" ]] || [[ "$GCC_VERSION" == "gcc-11" ]]; then 
        GCC_VERSION=gcc-8
    fi
    BUILT_BY_GCC_FLAG=" \\\\\n${BUILT_BY_GCC_FLAG_PREFIX}${GCC_VERSION}"
    NUMBER_OF_CONFIGURATION_FLAGS=$((NUMBER_OF_CONFIGURATION_FLAGS+1))
}

addAndCutOptionalFlags()
{
    debug "Parsing all nginx configuration flags"
    CC_EXTRA_PREFIX="EXTRA_CC_OPT="
    CC_OPTIONAL_FLAG_PREFIX="--with-cc-opt="
    LD_OPTIONAL_FLAG_PREFIX="--with-ld-opt="
    local argc=$#
    local argv=("$@")
    for (( i = 0; i < $argc; i++ )); do
        if [[ ${argv[i]} == *"${CC_OPTIONAL_FLAG_PREFIX}"* ]]; then
            debug "Successfully added compilation flags"
            CONFIGURATION_FLAGES_NEED_TO_BE_PARSED="${CONFIGURATION_FLAGES_NEED_TO_BE_PARSED}${argv[i]}"
            i=$((i+1))
            IFS=" "
            addCCFlagsWithoutSpecsLocalFlag ${argv[i]}
            CC_OPTIONAL_FLAGS="${CC_EXTRA_PREFIX}\"${CC_OPTIONAL_FLAGS}\""
        elif [[ ${argv[i]} == *"${LD_OPTIONAL_FLAG_PREFIX}"* ]]; then
            CONFIGURATION_FLAGES_NEED_TO_BE_PARSED="${CONFIGURATION_FLAGES_NEED_TO_BE_PARSED}${argv[i]}"
            i=$((i+1))
        else
            CONFIGURATION_FLAGES_NEED_TO_BE_PARSED="${CONFIGURATION_FLAGES_NEED_TO_BE_PARSED}${argv[i]}"
        fi
    done
    debug "Successfully finished adding optional flags"
    }

addCCFlagsWithoutSpecsLocalFlag()
{
    local argc=$#
    local argv=("$@")
    SPECS_FLAG_PREFIX="-specs="
    NO_ERROR_PREFIX="-Wno-error="
    FCF_PROTECTION_PREFIX="-fcf-protection"
    FSTACK_PREFIX="-fstack-clash-protection"
    
    for (( j = 0; j < $argc; j++ )); do
        if [[ ! ${argv[j]} =~ ^${SPECS_FLAG_PREFIX} ]] && \
        [[ ! ${argv[j]} =~ ^${NO_ERROR_PREFIX} ]] && \
        [[ ! ${argv[j]} =~ ^${FSTACK_PREFIX} ]] && \
        [[ ! ${argv[j]} =~ ^${FCF_PROTECTION_PREFIX} ]]; \
        then
            CC_OPTIONAL_FLAGS="${CC_OPTIONAL_FLAGS} ${argv[j]}"
        fi
        done
    CC_OPTIONAL_FLAGS=`echo $CC_OPTIONAL_FLAGS | grep ^"-"`
}

addRequiredFlags()
{
    local argc=$#
    local argv=("$@")
    CC_OPTIONAL_FLAG_PREFIX="--with-cc-opt="
    LD_OPTIONAL_FLAG_PREFIX="--with-ld-opt="
    ADDITIONAL_MODULE_FLAG_PREFIX="--add-module="
    DYNAMIC_MODULE_FLAG_PREFIX="--add-dynamic-module="
    BUILD_FLAG_PREFIX="--build="
    OPENSSL_VERSION_PREFIX="--with-openssl="
    OPENSSL_OPT_PREFIX="--with-openssl-opt="
    PCRE_FOLDER_PREFIX="--with-pcre="
    HPACK_ENC_PREFIX="--with-http_v2_hpack_enc"
    AUTH_JWT_PREFIX="--with-http_auth_jwt_module"
    F4F_PREFIX="--with-http_f4f_module"
    HLS_PREFIX="--with-http_hls_module"
    SESSION_LOG_PREFIX="--with-http_session_log_module"
    COMMON_PREFIX="--"
    WITH_CC_PREFIX="--with-cc"

    for (( i = 1; i < $argc; i++ )); do
        if [[ "${argv[i]}" =~ ^${COMMON_PREFIX} ]] && \
        [[ ! ("${argv[i]}" =~ ^${CC_OPTIONAL_FLAG_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ^${LD_OPTIONAL_FLAG_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${ADDITIONAL_MODULE_FLAG_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${OPENSSL_VERSION_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${OPENSSL_OPT_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${PCRE_FOLDER_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${DYNAMIC_MODULE_FLAG_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${BUILD_FLAG_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${AUTH_JWT_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${F4F_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${HLS_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${SESSION_LOG_PREFIX}) ]] && \
		[[ ! ("${argv[i]}" =~ ${WITH_CC_PREFIX}) ]] && \
        [[ ! ("${argv[i]}" =~ ${HPACK_ENC_PREFIX}) ]] ; \
        then
            debug "Adding configuration flag: ${argv[i]}\n"
            NUMBER_OF_CONFIGURATION_FLAGS=$((NUMBER_OF_CONFIGURATION_FLAGS+1))
            CONFIGURATION_FLAGS="${CONFIGURATION_FLAGS} \\\\\n${argv[i]}"
        fi
    done
    COMBINED_CONFIGURATION_FLAGS="${CONFIGURATION_FLAGS}"
    debug "Successfully added nginx configuration flags"
}

add_nginx_and_release_versions()
{
    echo -e "NGINX_VERSION=\"${NGINX_VERSION}\"" >> ${FILE_NAME}
    RELEASE_VERSION=`cat /etc/*-release | grep -i "PRETTY_NAME\|Gaia" | cut -d"\"" -f2`
    echo -e "RELEASE_VERSION=\"${RELEASE_VERSION}\"" >> ${FILE_NAME}
}

initializeEnviroment
echo -e "Open-appsec Nginx version extractor\n"
check_flags_options "$@"
_main 

