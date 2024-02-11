#!/bin/bash

source /etc/conf.d/routes-setup

test -z $LOG_FILE && LOG_FILE=/dev/null

function print_debug
{
	test $DEBUG -eq 1 && echo ' [DEBUG] '$@  | tee -a $LOG_FILE
}

function print_notice
{
	echo $@ | tee -a $LOG_FILE
}

function exec_command
{
	local command=$@
	print_debug "- running command: '"$command"'"
	$command &>> $LOG_FILE
}

function set_rp_filter()
{
	local dev=$1
	local value=$2
	local rp_filter_path="/proc/sys/net/ipv4/conf/${dev}/rp_filter"
	if [ $(cat $rp_filter_path) -eq $value ]
	then
		print_debug "Setting mode '$value' for device '${dev}'..."
		echo $value >> $rp_filter_path
	fi
}

function add_rule()
{
	local table_name=$1
	local chain_name=$2
	shift 2
	local rule="$@"
	print_debug "Checking if table $table_name has been created..."
	if [ "$(eval echo \$table_${table_name}_created)" != "1" ]
	then
		print_debug "Creating table '$table_name'"
		exec_command nft add table ${table_name}
		eval export table_${table_name}_created=1
	fi
	print_debug "Checking if chain $chain_name in table $table_name has been created..."
	if [ "$(eval echo \$chain_${table_name}_${chain_name}_created)" != "1" ]
	then
		print_debug "Creating chain $chain_name in table $table_name..."
  		exec_command nft add chain ${table_name} ${chain_name} { type nat hook ${chain_name} priority 100\;}
		eval export chain_${table_name}_${chain_name}_created=1
	fi
	exec_command nft add rule ${table_name} ${chain_name} ${rule} 
}


# Build our arrays.
print_debug "Starting operations on $(date)..."
print_debug "Loading outbounds..."
for o in $OUTBOUNDS
do
	 IFS=":" read name dev ip gw <<< "$o"
	 eval outbounds_dev_${name}=$dev
	 eval outbounds_ip_${name}=$ip
	 eval outbounds_gw_${name}=$gw
	 print_debug Added outbound: $name dev $(eval echo \$outbounds_dev_${name}) ip $(eval echo \$outbounds_ip_${name}) gw $(eval echo \$outbounds_gw_${name})
done

test -z $1 || DEFAULT_ROUTE=$1
print_notice "Default route will be: '$DEFAULT_ROUTE'"

WAN_DEV=$(eval echo \$outbounds_dev_${DEFAULT_ROUTE})
WAN_IP=$(eval echo \$outbounds_ip_${DEFAULT_ROUTE})
WAN_GW=$(eval echo \$outbounds_gw_${DEFAULT_ROUTE})
if [ "$WAN_DEV" != "" -a "$WAN_IP" != "" -a "$WAN_GW" != "" ]
then

	print_debug "Clearing existing rules & routes..."
  	exec_command nft flush table nat
  	exec_command nft delete table nat
	exec_command ip route del default

	print_notice "Adding fixed routes:"
	for r in $FIXED_ROUTES
	do
		IFS=":" read destination out <<< "$r"
		print_notice " - fixed route to '$destination' via '$out'." 
		print_debug "Clearing prvious routes for $destination"
		exec_command ip route del $destination

		FIXED_DEV=$(eval echo \$outbounds_dev_${out})
		FIXED_IP=$(eval echo \$outbounds_ip_${out})
		FIXED_GW=$(eval echo \$outbounds_gw_${out})
		if [ "${FIXED_DEV}" != "" -a "${FIXED_IP}" != "" -a "${FIXED_GW}" != "" ]
		then
			print_debug "Setting up route and SNAT for $destination"
			add_rule $TABLE_NAME postrouting oifname "${FIXED_DEV}" ip daddr $destination snat to ${FIXED_IP}
			exec_command ip route add $destination via $FIXED_GW dev $FIXED_DEV
		else
			print_notice " - unable to set fixed route because '$out' is invalid."
		fi
	done

	print_notice "Adding user routes:"
	for u in $USER_ROUTES
	do
		IFS=":" read username out <<< "$u"
		USER_DEV=$(eval echo \$outbounds_dev_${out})
		USER_IP=$(eval echo \$outbounds_ip_${out})
		USER_GW=$(eval echo \$outbounds_gw_${out})
		if [ "${FIXED_DEV}" != "" -a "${FIXED_IP}" != "" -a "${FIXED_GW}" != "" ]
		then
			userid=$(id -u $username)
			if [ $userid -ne 0 ]
			then
				print_debug "Creating routing table '$userid'..."
				exec_command ip route flush table ${userid}
				exec_command ip route add default via ${USER_GW} dev ${USER_DEV} table ${userid}

				print_debug "Setting up route for user '$username'..."
				exec_command ip rule add uidrange ${userid}-${userid} lookup ${userid}

				set_rp_filter ${USER_DEV} 2
			else
				print_notice " - Username '$username' seems to be invalid."
			fi
		else
			print_notice " - unable to set user route because '$out' is invalid."
		fi
	done

	print_notice "Adding default rules..."
	add_rule $TABLE_NAME postrouting oifname "${WAN_DEV}" iifname ${INTERNAL} snat to ${WAN_IP}
	exec_command ip route add default via ${WAN_GW} dev ${WAN_DEV}

	if [ -n $REDIRECT_DNS ]
	then
		print_notice "Rerouting all DNS queries to port '$REDIRECT_DNS'..."
		add_rule $TABLE_NAME prerouting iifname "$INTERNAL" udp dport 53 redirect to $REDIRECT_DNS
	fi

	print_notice "Setting up connectivity watchdog..."

	print_notice "All done!"
	exit 0

else

	print_notice "ERROR: invalid $DEFAULT_ROUTE"
	exit 255

fi


# Notes:
#   This script does not REMOVE fixed route or user routes that have been REMOVED from the configuration file, but will add new ones or edit existing ones.
