#!/bin/bash
# By Willy Gardiol, provided under the GPLv3 License. https://www.gnu.org/licenses/gpl-3.0.html
# Publicly available at: https://github.com/gardiol/routes-setup
# You can contact me at willy@gardiol.org

# Declare some configuration arrays
declare -A EXTERNAL_IF
declare -A EXTERNAL_IP
declare -A EXTERNAL_GW
declare -A EXTERNAL_STATUS
declare -A FIXED_ROUTES
declare -A USER_ROUTES

# Default values before the config file is loaded
DEBUG=0
TEST_ONLY=1
LOG_FILE="/dev/null"
ENABLE_EMAIL=0
ROUTE_CHECK_INTERVAL=60
ROUTE_CHECK_IP="8.8.8.8 1.1.1.1"


########## Service functions ##########
function print_debug
{
	[ ${DEBUG} -eq 1 ] && echo ' [DEBUG] '$@  | tee -a "${LOG_FILE}"
}

function print_notice
{
	echo $@ | tee -a "${LOG_FILE}"
}

function print_error
{
	echo ' [ERROR] '$@ | tee -a "${LOG_FILE}"
}

function print_error_email
{
	print_error $@
	if [ ${ENABLE_EMAIL} -eq 1 ]
	then
		(echo "Subject: ${EMAIL_SUBJECT}"; echo $@) | sendmail -F "${EMAIL_SENDER_NAME}" -f "${EMAIL_SENDER_ADDRESS}" ${EMAIL_RECEIVER_ADDRESS}
	fi
}

function print_error
{
	echo ' [ERROR] '$@ | tee -a "${LOG_FILE}"
}

# Execute a command, log it and obey the TEST_ONLY flag
function exec_command
{
	local ret=255
	print_notice "- running command: '""$@""'"
	if [ ${TEST_ONLY} -eq 1 ]
	then
		print_notice " (command not executed because TEST_ONLY=1) "
		ret=0
	else
		"$@" &>> "${LOG_FILE}"
		ret=$?
		echo "ret = '${ret}'" &>> "${LOG_FILE}"
	fi
	return ${ret}
}
#
# Execute a command, don't log it
function exec_command_nolog
{
	local ret=255
	if [ ${TEST_ONLY} -eq 1 ]
	then
		print_notice " (command '$@' not executed because TEST_ONLY=1) "
		ret=0
	else
		"$@" &>> "/dev/null"
		ret=$?
	fi
	return ${ret}
}

# Set a value of rt_filter for a specific interface, but don't if it's already set
function set_rp_filter()
{
	local dev=$1
	local value=$2
	local rp_filter_path="/proc/sys/net/ipv4/conf/${dev}/rp_filter"
	if [ $(cat ${rp_filter_path}) -ne ${value} ]
	then
		print_debug "Setting mode '${value}' for device '${dev}'..."
		echo ${value} >> ${rp_filter_path}
		print_debug "Mode for device '${dev}' is: '"$(cat ${rp_filter_path})"'."
	else
		print_debug "Not setting mode for '${dev}', value is already '${value}'."
	fi
}

# Add a new rule to an nft table/chain. Create the table and the chain if needed
function add_rule()
{
	local table_name=$1
	local chain_name=$2
	shift 2
	local rule="$@"
	print_debug "Checking if table ${table_name} has been created..."
	if nft list table ${table_name} &> /dev/null
	then
		print_debug "Table '${table_name}' exist."
	else
		print_debug "Creating table '${table_name}'"
		exec_command nft add table ${table_name}
	fi
	print_debug "Checking if chain '${chain_name}' in table '${table_name}' has been created..."
	if nft list chain ${table_name} ${chain_name} &> /dev/null
	then
		print_debug "Chain '${chain_name}' in table '${table_name}' exist."
	else
		print_debug "Creating chain '${chain_name}' in table '${table_name}'..."
  		exec_command nft add chain ${table_name} ${chain_name} { type nat hook ${chain_name} priority 100\;}
	fi
	print_debug "Adding rule '${rule}' to chain '${chain_name}' in table '${table_name}'..."
	exec_command nft add rule ${table_name} ${chain_name} ${rule} 
}

######## Load configuration and set sane defaults ##########

CONFIG_FILE="/etc/routes-setup.conf"
print_notice "Loading configuration from '${CONFIG_FILE}'..."
if source "${CONFIG_FILE}" 
then
	if [ "${ROUTE_CHECK_IP}" = "" ]
	then
		ROUTE_CHECK_IP="8.8.8.8 1.1.1.1"
	fi
	if [ ${ROUTE_CHECK_INTERVAL} -lt 60 ]
	then
		ROUTE_CHECK_INTERVAL=60
	fi

	if [ ${ENABLE_EMAIL} -eq 1 ]
	then
		if [ "${EMAIL_SENDER_NAME}" = "" -o "${EMAIL_RECEIVER_ADDRESS}" = "" -o "${EMAIL_SENDER_ADDRESS}" = "" ]
		then
			print_notice "EMAIL_SENDER_NAME, EMAIL_SENDER_ADDRESS and EMAIO_RECEIVER_ADDRESS are mandatory: disabling email reporting."
			ENABLE_EMAIL=0
		else
			if [ "${EMAIL_SUBJECT}" = "" ]
			then
				EMAIL_SUBJECT="Routes-Setup"
			fi
		fi
	fi
else
	print_notice "Unable to open and parse '${CONFIG_FILE}'"
	exit 255
fi

# No need to edit the table name
TABLE_NAME="routes-setup"

# Force debug in TEST ONLY
[ ${TEST_ONLY} -eq 1 ] && DEBUG=1

# Check valid log file
[ "${LOG_FILE}" = "" ] && LOG_FILE="/dev/null"
if [ ! -e "${LOG_FILE}" ]
then
	touch ${LOG_FILE}
fi

# Parse all externals and check them...
print_debug "Starting operations on $(date)..."
OUTBOUND=
for o in ${EXTERNAL}
do
	valid=1
	if [ "${EXTERNAL_IF[$o]}" = "" ]
	then
		print_error "Missing EXTERNAL_IF[$o]!"
		valid=0
	fi
	if [ "${EXTERNAL_IP[$o]}" = "" ]
	then
		print_error "Missing EXTERNAL_IP[$o]!"
		valid=0
	fi
	if [ "${EXTERNAL_GW[$o]}" = "" ]
	then
		print_error "Missing EXTERNAL_GW[$o]!"
		valid=0
	fi
	if [ "${EXTERNAL_STATUS[$o]}" = "" ]
	then
		print_debug "Missing EXTERNAL_STATUS[$o]: default to 'failback'."
		EXTERNAL_STATUS[$o]="failback"
	fi
	
	if [ ${valid} -eq 1 ]
	then
		print_debug "Added external interface '${o}' dev '${EXTERNAL_IF[$o]}' ip '${EXTERNAL_IP[$o]}' gw '${EXTERNAL_GW[$o]}' as '${EXTERNAL_STATUS[$o]}'"
		OUTBOUND="${OUTBOUND} ${o}"
	else
		print_error "Skipped external interface '${o}'."
	fi
done


########## Main cycle ##########
# Setup the external connections
# then monitor the default route
# reset the connections to a failback in case the default route fails.
#

# If no default route can be defined, set this and wait
unable_to_proceed=0
# On first cycle, all the rules need to be set.
rules_applied=0
while [ true ]
do
	if [ ${rules_applied} -eq 0 -a ${unable_to_proceed} -eq 0 ]
	then
		print_debug "Clearing existing rules & routes..."
		# Flushing and deleting the nft table is enough to delete all rules associated:
  		exec_command nft flush table ${TABLE_NAME}
  		exec_command nft delete table ${TABLE_NAME}
		# Properly clearing all routes instead is more complicated. Here at least let's clear the default one:
		exec_command ip route del default

		# Determine DEFAULT external interface:
		wan_dev=
		wan_ip=
		wan_gw=
		wan_name=
		# First of all, we look for one interface already defined as "default":
		for out in ${OUTBOUND}
		do
			if [ "${EXTERNAL_STATUS[${out}]}" = "default" ]
			then
				wan_dev=${EXTERNAL_IF[${out}]}
				wan_ip=${EXTERNAL_IP[${out}]}
				wan_gw=${EXTERNAL_GW[${out}]}
				wan_name=${out}
				break
			fi
		done
		# If we didnt find one, let's find the first "failback" available:
		if [ "${wan_name}" = "" ]
		then
			for out in ${OUTBOUND}
			do
				if [ "${EXTERNAL_STATUS[${out}]}" = "failback" ]
				then
					wan_dev=${EXTERNAL_IF[${out}]}
					wan_ip=${EXTERNAL_IP[${out}]}
					wan_gw=${EXTERNAL_GW[${out}]}
					wan_name=${out}
					EXTERNAL_STATUS[${out}]="default"
					break
				fi
			done
		fi

		# We should now have found one interface...
		if [ "${wan_name}" != "" ]
		then
			print_notice "Selected '${wan_name}' as default route..."
			print_debug "Default route identified as '${wan_dev}' (ip:${wan_ip}) gw '${wan_gw}'"
			add_rule ${TABLE_NAME} postrouting oifname "${wan_dev}" iifname ${INTERNAL} snat to ${wan_ip}
			exec_command ip route add default via ${wan_gw} dev ${wan_dev}
		
			# DNS redirection for the internal network, needs to be added again upon each table flush, so it's here
			if [ ${REDIRECT_DNS} -eq 1 ]
			then
				print_notice "Rerouting all DNS queries..."
				add_rule ${TABLE_NAME} prerouting iifname "${INTERNAL}" udp dport 53 redirect to 53
				add_rule ${TABLE_NAME} prerouting iifname "${INTERNAL}" tcp dport 53 redirect to 53
				add_rule ${TABLE_NAME} prerouting iifname "${INTERNAL}" udp dport 853 redirect to 853
				add_rule ${TABLE_NAME} prerouting iifname "${INTERNAL}" tcp dport 853 redirect to 853
			fi

			print_notice "Adding fixed routes..."
			for out in ${OUTBOUND}
			do
				[ "${FIXED_ROUTES[${out}]}" != "" ] && {
					if [ "${EXTERNAL_STATUS[${out}]}" != "failed" ]
					then
						for d in ${FIXED_ROUTES[${out}]}
						do
							destination=${d%:*}
							role=${d#*:}
							exec_command ip route del ${destination}
							fixed_dev=${EXTERNAL_IF[${out}]}
							fixed_ip=${EXTERNAL_IP[${out}]}
							fixed_gw=${EXTERNAL_GW[${out}]}
							if [ "${fixed_dev}" != "" -a "${fixed_ip}" != "" -a "${fixed_gw}" != "" ]
							then
								print_debug "Setting up route and SNAT for ${destination}"
								add_rule ${TABLE_NAME} postrouting oifname "${fixed_dev}" ip daddr ${destination} snat to ${fixed_ip}
								exec_command ip route add ${destination} via ${fixed_gw} dev ${fixed_dev}
							else
								print_error " - unable to set fixed route for destination '${destination}' because '${out}' is invalid."
							fi
						done
					else	
						print_error " - unable to set fixed routes for destinations '${FIXED_ROUTES[${out}]}' because '${out}' status is FAILED."
					fi
				} # no fixed routes for this destination
			done # fixed routes
	
			print_notice "Adding user routes..."
			for out in ${OUTBOUND}
			do
				[ "${USER_ROUTES[${out}]}" != "" ] && {
					if [ "${EXTERNAL_STATUS[${out}]}" != "failed" ]
					then
						for u in ${USER_ROUTES[${out}]}
						do
							username=${u%:*}
							role=${u#*:}
							user_dev=${EXTERNAL_IF[${out}]}
							user_ip=${EXTERNAL_IP[${out}]}
							user_gw=${EXTERNAL_GW[${out}]}
							if [ "${user_dev}" != "" -a "${user_ip}" != "" -a "${user_gw}" != "" ]
							then
								userid=$(id -u ${username})
								if [ ${userid} -gt 0 ]
								then
									print_debug "Creating routing table '${userid}'..."
									exec_command ip route flush table ${userid}
									exec_command ip route add default via ${user_gw} dev ${user_dev} table ${userid}
		
									print_debug "Setting up route for user '${username}(${userid})'..."
									exec_command ip rule add uidrange ${userid}-${userid} lookup ${userid}
									set_rp_filter ${user_dev} 2
								else
									print_error " - Username '${username}' seems to be invalid."
								fi
							else
								print_error " - unable to set route for user '${username}(${userid})' because '$out' is invalid."
							fi
						done
					else
						print_error " - unable to set user routes '${USER_ROUTES[${out}]}' because '${out}' status is FAILED."
					fi
				} # no user routes for this destination
			done # user routes

			print_notice "Configuration ready."
			rules_applied=1
			# A small delay here proved userful to prevent default-route being immediately killed but subsequent checks
			sleep 1

		else # default route not found
			print_error_email "Unable to setup default route: no EXTERNAL_STATUS['default'] can be identified! Giving up for good."
			unable_to_proceed=1
		fi # Default route set

	else # unable to proceed, or route/rules already set (no default route change).

		sleep ${ROUTE_CHECK_INTERVAL}
	
		# Status check for all interfaces...
		for out in ${OUTBOUND}
		do
			gw=${EXTERNAL_GW[${out}]}
			old_status=${EXTERNAL_STATUS[${out}]}
			#  first of all, check if gateway is reachable
			exec_command_nolog ping -n -q -c 1 -W 1 ${gw} 2> /dev/null
			if [ $? -ne 0 ]
			then # gw ping failed
				# If the gateway is not reachable, set the route as failed
				print_error_email "Unable to ping gw '${gw}' for interface '${out}'"
				EXTERNAL_STATUS[${out}]="failed"
				if [ "${old_status}" = "default" ]
				then # If this was the default interface, notify...
					# reset rules applied, so that a new default route can be selected...
					rules_applied=0
					print_error "Default gateway cannot be reached! Default interface is down."
				fi
			else # gw pings ok
				if [ "${old_status}" = "failed" ]
				then # If the interface was failed before, set it back to enabled
					EXTERNAL_STATUS[${out}]="failback"
					# Maybe this can become the new default route? Let's try...
					unable_to_proceed=0
					print_debug "Interface '${out}' seems available again...."
				elif [ "${old_status}" = "default" ]
				then # If this is the default interface, check external reacheability
					# Default route checking means to ping ALL defined destinations and fail if ALL of them fails (one or more might be down by themselves)
					at_least_one_ping_ok=0
					for ip in ${ROUTE_CHECK_IP}
					do
						exec_command_nolog ping -n -q -c 1 -W 1 ${ip} 2> /dev/null
						if [ $? -eq 0 ]
						then
							at_least_one_ping_ok=1
						else
							print_debug "Ping to '${ip}' failed."
						fi
					done
					if [ ${at_least_one_ping_ok} -eq 0 ]
					then
						print_error_email "Unable to reach any predefined remotes! Default route '${out}' has failed!"
						rules_applied=0
					fi
				fi 
			fi # if ping gw 
		done # for all interfaces to check

	fi # default route was ok
done

# Notes:
#   This script does not REMOVE fixed route or user routes that have been REMOVED from the configuration file, but will add new ones or edit existing ones.
