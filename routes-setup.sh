#!/bin/bash
# By Willy Gardiol, provided under the GPLv3 License. https://www.gnu.org/licenses/gpl-3.0.html
# Publicly available at: https://github.com/gardiol/routes-setup
# You can contact me at willy@gardiol.org

export myself=$0

source /etc/conf.d/routes-setup

# Force debug in TEST ONLY
test ${TEST_ONLY} -eq 1 && DEBUG=1

# Check valid log file
test -z ${LOG_FILE} && LOG_FILE=/dev/null
if [ ! -e ${LOG_FILE} ]
then
	LOG_FILE=/dev/null
fi

# loggig, debugging and general print functions
function print_debug
{
	test ${DEBUG} -eq 1 && echo ' [DEBUG] '$@  | tee -a ${LOG_FILE}
}

function print_notice
{
	echo $@ | tee -a ${LOG_FILE}
}

function print_error
{
	echo ' [ERROR] '$@ | tee -a ${LOG_FILE}
}

# Execute a command, log it and obey the TEST_ONLY flag
function exec_command
{
	local command=$@
	print_notice "- running command: '"${command}"'"
	if [ ${TEST_ONLY} -eq 1 ]
	then
		print_notice " (command not executed because TEST_ONLY=1) "
	else
		${command} &>> ${LOG_FILE}
	fi
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

# This is the bulk of the action!

# Parse all outbounds into semi-dynamical arrays
print_debug "Starting operations on $(date)..."
print_debug "Loading outbounds..."
for o in ${OUTBOUNDS}
do
	 IFS=":" read name dev ip gw <<< "${o}"
	 eval outbounds_dev_${name}=${dev}
	 eval outbounds_ip_${name}=${ip}
	 eval outbounds_gw_${name}=${gw}
	 print_debug "Added outbound '${name}' dev '$(eval echo \$outbounds_dev_${name})' ip '$(eval echo \$outbounds_ip_${name})' gw '$(eval echo \$outbounds_gw_${name})'"
done

# Take default route from command-line (for manual call or watchdog call) if specified, otherwise go with default.
if [ $1 ]
then
	print_notice "Using default route specified on command line: '$1'"
	DEFAULT_ROUTE=$1
else
	print_notice "Default route will be: '${DEFAULT_ROUTE}'"
fi

# Check if default route is correct
wan_dev=$(eval echo \$outbounds_dev_${DEFAULT_ROUTE})
wan_ip=$(eval echo \$outbounds_ip_${DEFAULT_ROUTE})
wan_gw=$(eval echo \$outbounds_gw_${DEFAULT_ROUTE})
if [ "${wan_dev}" != "" -a "${wan_ip}" != "" -a "${wan_gw}" != "" ]
then

	print_debug "Clearing existing rules & routes..."
	# Flusing and deleting the nft table is enough to delete all rules associated:
  	exec_command nft flush table ${TABLE_NAME}
  	exec_command nft delete table ${TABLE_NAME}
	# Properly clearing all routes instead is more complicated. Here at least let's clear the default one:
	exec_command ip route del default

	print_notice "Adding fixed routes:"
	for r in ${FIXED_ROUTES}
	do
		IFS=":" read destination out <<< "${r}"
		print_notice " - fixed route to '${destination}' via '${out}'." 
		print_debug "Clearing prvious routes for ${destination}"
		exec_command ip route del ${destination}

		fixed_dev=$(eval echo \$outbounds_dev_${out})
		fixed_ip=$(eval echo \$outbounds_ip_${out})
		fixed_gw=$(eval echo \$outbounds_gw_${out})
		if [ "${fixed_dev}" != "" -a "${fixed_ip}" != "" -a "${fixed_gw}" != "" ]
		then
			print_debug "Setting up route and SNAT for ${destination}"
			add_rule ${TABLE_NAME} postrouting oifname "${fixed_dev}" ip daddr ${destination} snat to ${fixed_ip}
			exec_command ip route add ${destination} via ${fixed_gw} dev ${fixed_dev}
		else
			print_error " - unable to set fixed route for destination '${destination}' because '${out}' is invalid."
		fi
	done

	print_notice "Adding user routes:"
	for u in ${USER_ROUTES}
	do
		IFS=":" read username out <<< "${u}"
		user_dev=$(eval echo \$outbounds_dev_${out})
		user_ip=$(eval echo \$outbounds_ip_${out})
		user_gw=$(eval echo \$outbounds_gw_${out})
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
				print_notice " - Username '${username}' seems to be invalid."
			fi
		else
			print_error " - unable to set route for user '${username}(${userid})' because '$out' is invalid."
		fi
	done

	print_notice "Adding default rules..."
	add_rule ${TABLE_NAME} postrouting oifname "${wan_dev}" iifname ${INTERNAL} snat to ${wan_ip}
	exec_command ip route add default via ${wan_gw} dev ${wan_dev}

	# DNS redirection for the internal network
	if [ ${REDIRECT_DNS} ]
	then
		print_notice "Rerouting all DNS queries to port '${REDIRECT_DNS}'..."
		add_rule ${TABLE_NAME} prerouting iifname "${INTERNAL}" udp dport 53 redirect to ${REDIRECT_DNS}
	fi

	# Watchdog for when the active route goes down
	if [ "${FAILBACK_ROUTE}" -a "${FAILBACK_ROUTE_CHECK}" ]
	then
		print_notice "Setting up connectivity watchdog..."
		(
		DEFAULT_IS_DOWN=0
		print_debug "Going to check '${FAILBACK_ROUTE_CHECK}' periodically (every ${FAILBACK_ROUTE_INTERVAL}s)..."
		while [ ${DEFAULT_IS_DOWN} -eq 0 ]
		do
			sleep ${FAILBACK_ROUTE_INTERVAL}
			DEFAULT_IS_DOWN=$(cat < /dev/null > /dev/tcp/${FAILBACK_ROUTE_CHECK}; echo $?)
		done
		print_notice "At '$(date)' default route '${DEFAULT_ROUTE}' seems down: switching to '${FAILBACK_ROUTE}'..."
		${myself} ${FAILBACK_ROUTE}
		exit 0
		)&
	else
		print_debug "Not setting up watchdog because FAILBACK_ROUTE or FAILBACK_ROUTE_CHECK are not set."
	fi

	print_notice "All done!"
	exit 0

else

	print_error "Invalid ${DEFAULT_ROUTE}"
	exit 255

fi


# Notes:
#   This script does not REMOVE fixed route or user routes that have been REMOVED from the configuration file, but will add new ones or edit existing ones.
