#!/bin/bash
# Copyright (c) 2020, Netskope, Inc. All rights reserved.
# Distr. "as is". Contact Netskope support.
# VERSION: 22.0 - nsclientconfig.sh copies NS Client install param file (nsinstparams.json)
# SYNOPSIS: nsclientconfig.sh <dummy1> <dummy2> <currentUsername> <tenant url> <org Key> <UPN (optional)>
# DESCRIPTION: For AD/JSS users, configures for Netskope Client installer.
# History: V1.0-V22.0 (Reduced for brevity)

# Intune Deployment examples
set -- 0 0 0 addon- < tenant name >.< tenant domain >.goskope.com < Org ID > < plist file name > preference_email enrollauthtoken= < authentication token > enrollencryptiontoken=< encryption token >

argstring="$*"
upnmode=0; perusermode=0; email_from_pref=0; cli_mode=0; idP_mode=0; silent_mode=0
enrollauthtoken=0; enrollencryptiontoken=0; enroll_key_mode=0
enforceFailClose=0; steeringProfileID_val=""; frequency_val="5" # Default 5 min
host_val=""; token_val=""; enrollauthtoken_option=""; enrollencryptiontoken_option=""

if [[ "$6" == "upn" ]]; then echo "UPN mode configured"; upnmode=1; fi
if echo "$argstring" | grep -q "\bperuserconfig\b"; then echo "Peruserconfig mode configured"; perusermode=1; fi
if echo "$argstring" | grep -q "\bpreference_email\b"; then echo "Preference email configured"; email_from_pref=1; fi
if echo "$argstring" | grep -q "\bcli_mode\b"; then echo "CLI mode configured"; cli_mode=1; fi
if [[ "$4" == "idp" ]]; then echo "Idp mode configured"; idP_mode=1; fi
if echo "$argstring" | grep -iq "\bsilent_mode\b"; then echo "Silent mode configured"; silent_mode=1; fi

argArray=(`echo $argstring | tr ' ' ' '`)
for arg in "${argArray[@]}"; do
    if [[ "$arg" =~ "enrollauthtoken" ]]; then
        enrollauthtoken=1
        enrollauthtoken_option=`echo "$arg" | awk -F"=" '{print $2}'`
        enrollauthtoken_option="\"enrollauthtoken\": \"${enrollauthtoken_option}\""
        echo "Enroll using auth token"
    fi
    if [[ "$arg" =~ "enrollencryptiontoken" ]]; then
        enrollencryptiontoken=1
        enrollencryptiontoken_option=`echo "$arg" | awk -F"=" '{print $2}'`
        enrollencryptiontoken_option="\"enrollencryptiontoken\": \"${enrollencryptiontoken_option}\""
        echo "Enroll using encryption token"
    fi
    if [[ "$arg" =~ "mode" ]]; then
        browser_mode=`echo "$arg" | awk -F"=" '{print $2}'`
        browser_mode=", \"mode\": \"${browser_mode}\""
    fi
    if [[ "$arg" =~ "preferephemeral" ]]; then
        prefer_ephemeral=`echo "$arg" | awk -F"=" '{print $2}'`
        prefer_ephemeral=", \"preferEphemeral\": ${prefer_ephemeral}"
    fi
    if [[ "$arg" =~ "httpmethod" ]]; then
        http_method=`echo "$arg" | awk -F"=" '{print $2}'`
        http_method=", \"httpMethod\": \"${http_method}\""
    fi
    if [[ "$arg" =~ ^host= ]]; then host_val=`echo "$arg" | awk -F"=" '{print $2}'`; fi
    if [[ "$arg" =~ ^token= ]]; then token_val=`echo "$arg" | awk -F"=" '{print $2}'`; fi
    if [[ "$arg" =~ ^ENFORCEENROLLSTEERINGPROFILEID= ]]; then
        steeringProfileID_val=`echo "$arg" | awk -F"=" '{print $2}'`
        enforceFailClose=1
    fi
    if [[ "$arg" =~ ^ENFORCEENROLLFREQUENCY= ]]; then frequency_val=`echo "$arg" | awk -F"=" '{print $2}'`; fi

    if [ ! -z "$frequency_val" ]; then
        if ! [[ "$frequency_val" =~ ^[0-9]+$ ]]; then echo "Error: frequency must be numeric"; exit 1; fi
        if [ "$frequency_val" -lt 1 ] || [ "$frequency_val" -gt 1440 ]; then
            echo "Error: frequency must be 1-1440 min. Provided: $frequency_val"; exit 1
        fi
    fi
done

TEMP_BRANDING_DIR="/tmp/nsbranding"
NSINSTPARAM_JSON_FILE="$TEMP_BRANDING_DIR/nsinstparams.json"
TEMP_SILENTMODE_FILE="$TEMP_BRANDING_DIR/silent.conf"
TEMP_ENROLLMENT_TOKEN_FILE="$TEMP_BRANDING_DIR/enroll.conf"
NSUSERCONFIG_JSON_FILE="/Library/Application Support/Netskope/STAgent/nsuserconfig.json"
NSIDPCONFIG_FILE_PATH="/Library/Application Support/Netskope/STAgent/nsidpconfig.json"

optionalArgumentCnt=`expr $silent_mode + $enrollauthtoken + $enrollencryptiontoken`
minimumArg=`expr 6 + $optionalArgumentCnt`

if [ $# -lt $minimumArg ] && [ $idP_mode -eq 0 ]; then
   echo "Insufficient arguments. Usage examples:"
   echo "  Email: <dummy> <dummy> <user> <tenant url> <AD domain> <Org Key> [silent] [enrollauthtoken=t] [enrollencryptiontoken=t]"
   echo "  UPN: <dummy> <dummy> <user> <Adonman url> <Org Key> upn [pref_file] [silent] [enrollauthtoken=t] [enrollencryptiontoken=t]"
   echo "  Peruser: <dummy> <dummy> <user> <Adonman url> <Org Key> peruserconfig [fail-close*] [silent] [enrollauthtoken=t] [enrollencryptiontoken=t]"
   echo "  Pref Email: <dummy> <dummy> <dummy> <tenant url> <Org Key> <pref_file> preference_email [silent] [enrollauthtoken=t] [enrollencryptiontoken=t]"
   echo "  CLI: <dummy> <dummy> <dummy> <tenant url> <Org Key> cli_mode [silent]"
   echo "  IdP: <dummy> <dummy> <dummy> idp <domain> <tenant> <requestEmail 1/0> [peruserconfig] [fail-close*] [silent] [tokens] [mode=e|s] [preferephemeral=t|f] [httpmethod=p|g]"
   exit 1
fi

rm -rf $TEMP_BRANDING_DIR; mkdir -p $TEMP_BRANDING_DIR

loggedinusername=`stat -f '%Su' /dev/console`
userName="$3"
if [ "$userName" == "0" ]; then userName=$loggedinusername; fi
echo "User name: $userName"

if [ $idP_mode -eq 0 ]; then rm -f "${NSIDPCONFIG_FILE_PATH}"; fi

fail_close="false"; fail_close_no_npa="false"
if echo "$argstring" | grep -iq "fail-close-disable"; then fail_close="true"; fi
if echo "$argstring" | grep -iq "fail-close-no-npa"; then fail_close="true"; fail_close_no_npa="true"; fi

fail_close_option=""
if [ "$fail_close" = "true" ]; then
    fail_close_option=",\"failClose\": {\"fail_close\": \"$fail_close\",\"exclude_npa\": \"$fail_close_no_npa\"}"
fi

if [ $silent_mode -eq 1 ]; then echo "1" > "${TEMP_SILENTMODE_FILE}"; fi

if [ $enrollauthtoken -eq 1 ] || [ $enrollencryptiontoken -eq 1 ]; then
    enrollmentJSON="{"
    enrollmentJSON="$enrollmentJSON$enrollauthtoken_option"
    if [ $enrollauthtoken -eq 1 ] && [ $enrollencryptiontoken -eq 1 ]; then enrollmentJSON="$enrollmentJSON,"; fi
    enrollmentJSON="$enrollmentJSON $enrollencryptiontoken_option"
    enrollmentJSON="$enrollmentJSON}"
    echo "$enrollmentJSON" > "$TEMP_ENROLLMENT_TOKEN_FILE"
else
     echo "" > "$TEMP_ENROLLMENT_TOKEN_FILE"
fi
chmod 700 "$TEMP_ENROLLMENT_TOKEN_FILE"

if [ $idP_mode -eq 1 ]; then
    mkdir -p "/Library/Application Support/Netskope/STAgent"
    spDomain="$5"; spTenant="$6"
    requestEmailNode=" "
    if [ $# -gt 6 ] && [ $7 -gt 0 ]; then requestEmailNode=", \"requestEmail\": \"true\" "; fi

    host_provided=0; steering_provided=0; token_provided=0; tenant_provided=0
    if [ ! -z "$host_val" ]; then host_provided=1; fi
    if [ ! -z "$steeringProfileID_val" ]; then steering_provided=1; fi
    if [ ! -z "$token_val" ]; then token_provided=1; fi
    if [ ! -z "$spTenant" ]; then tenant_provided=1; fi
    total_provided=$((host_provided + steering_provided + token_provided + tenant_provided))

    if [ $steering_provided -ne 0 ] && [ $total_provided -ne 4 ]; then
        echo "Error: host, ENFORCEENROLLSTEERINGPROFILEID, Tenant name and token must all be provided or none."; exit 1
    fi

    echo "{ \"serviceProvider\": { \"domain\": \"$spDomain\", \"tenant\": \"$spTenant\" ${browser_mode} ${prefer_ephemeral} ${http_method} } $requestEmailNode }" > "${NSIDPCONFIG_FILE_PATH}"
    
    per_user_enabled="false"; if [ $perusermode -eq 1 ]; then per_user_enabled="true"; fi
    
    if [[ $perusermode -eq 1 || $enforceFailClose -eq 1 ]]; then
        json_config="{\"nsUserConfig\":{\"enablePerUserConfig\": ${per_user_enabled}, \"configLocation\": \"~/Library/Application Support/Netskope/STAgent\""
        mkdir -p "/Library/Application Support/Netskope/STAgent"
        json_config="$json_config, \"host\": \"$host_val\""
        json_config="$json_config, \"token\": \"$token_val\""
        if [ $enforceFailClose -eq 1 ]; then
            json_config="$json_config, \"enforceEnrollment\": {\"steeringProfileID\": \"$steeringProfileID_val\""
            json_config="$json_config, \"frequency\": \"$frequency_val\"}}"
        fi
        json_config="$json_config, \"autoupdate\": \"true\"$fail_close_option}}"
        echo "$json_config" > "${NSUSERCONFIG_JSON_FILE}"
    fi
exit 0
fi

if [ $perusermode -eq 1 ]; then
    echo -n > "${NSINSTPARAM_JSON_FILE}"
    mkdir -p "/Library/Application Support/Netskope/STAgent"
    addonUrl="$4"; orgkey="$5"
    if [[ $addonUrl != addon-* ]]; then echo "Addon url must start with addon-"; exit 1; fi
    echo "{\"nsUserConfig\":{\"enablePerUserConfig\": \"true\", \"configLocation\": \"~/Library/Application Support/Netskope/STAgent\", \"token\": \"$orgkey\", \"host\": \"$addonUrl\",\"autoupdate\": \"true\"$fail_close_option}}" > "${NSUSERCONFIG_JSON_FILE}"
exit 0
fi

if [ $email_from_pref -eq 1 ]; then
    echo -n > "${NSINSTPARAM_JSON_FILE}"
    tenantUrl="$4"; orgKey="$5"
    emailPrefFile='/Library/Managed Preferences/'$6
    if [ ! -f "$emailPrefFile" ]; then echo "$emailPrefFile not found, exiting"; exit 1; fi
    
    emailAddress=`defaults read "$emailPrefFile" email`
    if [ $? != 0 ]; then echo "Failed to read email from preference file, exiting error $?"; exit 1; fi
    
    IFS='@'; typeset -r splitEmailAddr2=($emailAddress)
    if [ ${#splitEmailAddr2[@]} -ne 2 ]; then echo "Invalid email address, exiting"; exit; fi

    mkdir -p $TEMP_BRANDING_DIR
    echo "{\"TenantHostName\":\"$tenantUrl\", \"Email\":\"$emailAddress\", \"OrgKey\":\"$orgKey\"}" > "${NSINSTPARAM_JSON_FILE}"
    if [ $? == 0 ]; then echo "$NSINSTPARAM_JSON_FILE created"; exit 0; fi
    echo "Failed to create $NSINSTPARAM_JSON_FILE"; exit 1
fi

if [ $cli_mode -eq 1 ]; then
    echo -n > "${NSINSTPARAM_JSON_FILE}"
    tenantUrl="$4"; orgKey="$5"
    
    emailAddress=$(adquery user "$loggedinusername" -P)
    if [ $? != 0 ]; then echo "Failed to read email from CLI, exiting error $?"; exit 1; fi

    mkdir -p $TEMP_BRANDING_DIR
    echo "{\"TenantHostName\":\"$tenantUrl\", \"Email\":\"$emailAddress\", \"OrgKey\":\"$orgKey\"}" > "${NSINSTPARAM_JSON_FILE}"

    if [ $? == 0 ]; then echo "$NSINSTPARAM_JSON_FILE created"; exit 0; fi
    echo "Failed to create $NSINSTPARAM_JSON_FILE"; exit 1
fi

if [ $upnmode -eq 1 ]; then
    echo -n > "${NSINSTPARAM_JSON_FILE}"
    addonUrl="$4"; orgkey="$5"
    if [[ $addonUrl != addon-* ]]; then echo "Addon url must start with addon-"; exit 1; fi

    emailPrefFileProvided=0
    if [ $# -ge 7 ]; then
        declare -i emptyArgs=0
        declare -i i=$#-1
        while [ $i -ge 6 ]; do
            if [ "${argArray[$i]}" == "" ]; then emptyArgs+=1; fi
            ((--i))
        done
        if [ `expr 6 + $optionalArgumentCnt + $emptyArgs` -lt $# ]; then emailPrefFileProvided=1; fi
    fi

    if [ $emailPrefFileProvided -eq 1 ]; then
        emailPrefFile='/Library/Managed Preferences/'$7
        if [ ! -f "$emailPrefFile" ]; then echo "$emailPrefFile not found, exiting"; exit 1; fi
        upn=`defaults read "$emailPrefFile" email`
    else
        domainName=`echo show com.apple.opendirectoryd.ActiveDirectory | scutil | grep DomainNameFlat | awk '{print $3}'`
        if [ $? -ne 0 ]; then echo "Failed to get domain name, exiting"; exit 1; fi
        
        counter=0
        while [ 1 ]; do
            upnAttr=`dscl /Active\ Directory/$domainName/All\ Domains -read /Users/$userName userPrincipalName`
            ret=$?
            if [ $ret -eq 0 ]; then break; fi
            counter=$((counter+1))
            if [ $counter -eq 5 ]; then echo "Failed to fetch upn after 5 attempts, error $ret"; exit 1; fi
            sleep 5
        done
        upn=${upnAttr:36}
    fi

    mkdir -p $TEMP_BRANDING_DIR
    echo "{\"AddonHostName\":\"$addonUrl\", \"Upn\":\"$upn\", \"OrgKey\":\"$orgkey\"}" > "${NSINSTPARAM_JSON_FILE}"
    echo "NS Client install param copied to $NSINSTPARAM_JSON_FILE."
else
    echo -n > "${NSINSTPARAM_JSON_FILE}"
    tenantUrl="$4"; domainName="$5"; orgKey="$6"

    counter=0
    while [ 1 ]; do
        emailidAttr=`dscl /Active\ Directory/$domainName/All\ Domains -read /Users/$userName mail`
        ret=$?
        if [ $ret -eq 0 ]; then break; fi
        counter=$((counter+1))
        if [ $counter -eq 5 ]; then echo "Failed to fetch email id after 5 attempts, error $ret"; exit 1; fi
        sleep 5
    done
    
    emailId=${emailidAttr:23}

    mkdir -p $TEMP_BRANDING_DIR
    echo "{\"TenantHostName\":\"$tenantUrl\", \"Email\":\"$emailId\", \"OrgKey\":\"$orgKey\"}" > "${NSINSTPARAM_JSON_FILE}"
    echo "NS Client install param copied to $NSINSTPARAM_JSON_FILE."
fi
exit 0
