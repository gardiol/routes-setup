#!/bin/bash

source /etc/conf.d/routes-setup

test -z $LOG_FILE && LOG_FILE=/dev/null

function print_debug
{
	test $DEBUG -eq 1 && echo ' [DEBUG] '$@  | tee -a $LOG_FILE
}

function exec_command
{
	local command=$@
	print_debug "- running command: '"$command"'"
	$command &>> $LOG_FILE
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
echo Default route will be: $DEFAULT_ROUTE | tee -a $LOG_FILE

WAN_DEV=$(eval echo \$outbounds_dev_${DEFAULT_ROUTE})
WAN_IP=$(eval echo \$outbounds_ip_${DEFAULT_ROUTE})
WAN_GW=$(eval echo \$outbounds_gw_${DEFAULT_ROUTE})
if [ "$WAN_DEV" != "" -a "$WAN_IP" != "" -a "$WAN_GW" != "" ]
then

	print_debug "Clearing existing rules & routes..."
  	exec_command nft flush table nat
  	exec_command nft delete table nat
	exec_command ip route del default

	print_debug "Creating nat table and chains..."
  	exec_command nft add table nat
  	exec_command nft add chain nat postrouting { type nat hook postrouting priority 100\;}

	echo "Adding fixed routes:" | tee -a $LOG_FILE
	for r in $FIXED_ROUTES
	do
		IFS=":" read destination out <<< "$r"
		echo " - fixed route to '$destination' via '$out'." | tee -a $LOG_FILE
		print_debug "Clearing prvious routes for $destination"
		exec_command ip route del $destination

		FIXED_DEV=$(eval echo \$outbounds_dev_${out})
		FIXED_IP=$(eval echo \$outbounds_ip_${out})
		FIXED_GW=$(eval echo \$outbounds_gw_${out})
		if [ "${FIXED_DEV}" != "" -a "${FIXED_IP}" != "" -a "${FIXED_GW}" != "" ]
		then
			print_debug "Setting up route and SNAT for $destination"
			exec_command nft add rule nat postrouting oifname "${FIXED_DEV}" ip daddr $destination snat to ${FIXED_IP}
			exec_command ip route add $destination via $FIXED_GW dev $FIXED_DEV
		else
			echo " - unable to set because '$out' is invalid." | tee -a $LOG_FILE
		fi
	done

	echo "Adding default rules..." | tee -a $LOG_FILE
  	exec_command nft add rule nat postrouting oifname "${WAN_DEV}" iifname ${INTERNAL} snat to ${WAN_IP}
	exec_command ip route add default via ${WAN_GW} dev ${WAN_DEV}

	echo "All done!" | tee -a $LOG_FILE
	exit 0

else

	echo ERROR: invalid $DEFAULT_ROUTE | tee -a $LOG_FILE
	exit 255

fi

