#!/bin/sh -e

SAVED_TRAPS="$(trap)"

tmp_dir=/tmp/rmc_update.$$
update_fsc_pid_file=$tmp_dir/update_fsc_pid
update_fsc_pid_file=$tmp_dir/update_rmc_pid

rmc_update_sigstop()
{
    set +x

    [ -s "$update_fsc_pid_file" ] && kill -9 $(cat $update_fsc_pid_file) 2>/dev/null
    [ -s "$update_rmc_pid_file" ] && kill -9 $(cat $update_rmc_pid_file) 2>/dev/null

    eval "$SAVED_TRAPS"
    set +e
}

trap rmc_update_sigstop USR1 KILL TERM EXIT QUIT INT 

TEMP=`getopt -o aFd:fhrp:s:v:w: --long all-rmc,flash,fw-directory:,fsc-only,check-health,rmc-sw-only,psql-db-ver:,specific-rack:,rmc-sw-version:,fsc-fw-version:  -n "r:h-update-rmc" -- "$@" || i-fail "Failed"`

eval set -- "$TEMP"

rmc_user_pass=
bot_api=

fcs_fw_ver=112
rmc_sw_ver=050
psql_db_ver=019

fw_dir=/home/lacitis/WORK/ROMS/GB

while :; do
    case "$1" in
    -a|--all-rmc) shift
        all_rmc=1
        ;;
    -F|--flash) shift
        opt_flash=1
        ;;
    -d|--fw-directory) shift
        fw_dir="$1"
				shift
        ;;
    -f|--fsc-only) shift
        fsc_only=1
        ;;
    -h|--check-health) shift
        check_health=1
        ;;
    -r|--rmc-sw-only) shift
        rmc_sw_only=1
        ;;
    -p|--psql-db-ver) shift
        psql_db_ver="$1"
				shift
        ;;
    -s|--specific-rmcs) shift
        opt_rmcs_list="$1"
				shift
        ;;
    -v|--rmc-sw-version) shift
        rmc_sw_ver="$1"
				shift
        ;;
    -w|--fsc-fw-version) shift
				fcs_fw_ver="$1"
				shift
        ;;
    --) shift
        break
        ;;
    *) i-fail "r:h-update-rmc: wrong option: $1"
        ;;
    esac
done

fscb_fw_dir=$fw_dir/BFGXA_V${fcs_fw_ver%??}.${fcs_fw_ver#1}
rmc_fw_dir=$fw_dir/rmc.v$rmc_sw_ver
psql_db_file=$rmc_fw_dir/dbRMC.v$psql_db_ver

dir_prefix=/var/log/rmc_update
unreachable_rmcs=$dir_prefix/unreachable.$$
problem_list=$dir_prefix/problem_list.$$
rack_health_list=$dir_prefix/rack_health_list.$$
update_process_log=$dir_prefix/update_process_log.$$
unreachable_rmc=$dir_prefix/unreachable_rmc.$$
update_rmc_pid_file=/tmp/update_rmc_pid.$$

mkdir -p $dir_prefix
mkdir -p $tmp_dir

[ -n "$all_rmc" ] && rmcs_list=$(curl -s $bot_api | sed -n '/.*[aA].rmm.*/p' | awk '{print $2 }' )
[ -f "$opt_rmcs_list" ] && rmcs_list=$(cat $opt_rmcs_list) || rmcs_list="$(printf $opt_rmcs_list | tr ',' '\n')"

check_fcs_fw_ver()
{
	fsc_ver_raw=$($ssh $rmc_a "ipmitool -H 192.168.1.10 -U admin -P password raw 0x06 0x01" || printf NULL)
	[ -n "$fsc_ver_raw" ] || printf "$rmc_a: Can't get FCSB FW version\n"|tee -a $update_process_log
  set -- $fsc_ver_raw 
	major="$((0x$3 & 0x7f))"
  minor="$4"
  current_fsc_fw_ver="$major$minor"
	printf "$rmc_a: FSCB FW ― ${current_fsc_fw_ver%??}.${current_fsc_fw_ver#?}\n" | tee -a $rack_health_list
}

check_rmc_sw_ver()
{
	#current_rmc_sw_ver=$($ssh $1 "grep 'RMC Version' /var/www/bmctree.php|sed -n 's,.*\([0-9]\)\.\([0-9]*\).*,\1\2,p'")
	currnet_rmc_sw_ver=$(curl "view-source:https://$1/bmctree.php" | sed -n 's,.*RMC Version:\s\+v\([0-9\.]\+\).*,\1,p' | sort -u)
	#current_rmc_sw_ver=$($ssh $1 "fgrep Version /var/www/bmctree.php | sed -n 's,.*RMC Version:\s\+v\([0-9\.]\+\).*,\1,p'" | sort -u)
	#TODO Check DB version checking
	current_psql_db_ver=$($ssh $1 "export PGPASSWORD=\"superuser\"; psql -U postgres -c 'SELECT \"dbVersion\" FROM \"tdUserDefine\"' dbRMC" 2>/dev/null | sed -n 's/.*\([0-9].[0-9][0-9]\).*/\1/p')
	printf "$1: RMC SW ― $current_rmc_sw_ver; pSQL DB ― $current_psql_db_ver\n" | tee -a $rack_health_list
	[ "$current_rmc_sw_ver" = "${rmc_sw_ver%??}.${rmc_sw_ver#?}" ] || { printf "$1: current RMC SW is old: $current_rmc_sw_ver != ${rmc_sw_ver%??}.${rmc_sw_ver#?}\n" >> $problem_list; return 1; } 
	[ "$current_psql_db_ver" = "${psql_db_ver%??}.${psql_db_ver#?}" ] || { printf "$1: current RMC pSQL DB is old: $current_psql_db_ver != ${psql_db_ver%??}.${psql_db_ver#?}\n" >> $problem_list; return 1; }
}

update_fsc_bmc()
{
	$rsync $fscb_fw_dir rmc@$rmc_a://home/rmc/ 2>> $problem_list|| { printf "$rmc_a: can't put FSCB $fscb_fw_dir\n" | tee -a $update_process_log; continue; }

	check_fcs_fw_ver
	if [ "$current_fsc_fw_ver" != "$fcs_fw_ver" ]; then 
		$ssh $rmc_a "rm /srv/tftp/*" ||:
		$ssh $rmc_a "cp /home/rmc/BFGXA_V${fcs_fw_ver%??}.${fcs_fw_ver#1}/fw/bfgxa$fcs_fw_ver.img /srv/tftp" 2>> $problem_list || { printf "Can't copy firmware binary to tftp directory on $rmc_a\n" | tee -a $update_process_log; continue; }
		$ssh $rmc_a "cd BFGXA_V${fcs_fw_ver%??}.${fcs_fw_ver#1}/utility/fwud/linux/; screen -d -m -S fcs_update sh ./remote_ud32.sh 192.168.1.10 admin password tftp://192.168.1.1/bfgxa$fcs_fw_ver.img"

		# FW upgrading process
		#TODO add expect monitoring to parse ending state or check the exit code status
		sleep 7m

		check_fcs_fw_ver
		[ "$current_fsc_fw_ver" != "$fcs_fw_ver" ] && { printf "$rmc_a: failed to upgrade FW of FSCB: $current_fsc_fw_ver != $fcs_fw_ver!\n" | tee -a $problem_list; continue; }
		else
			return 0;
	fi
		
}

set_rmcs_single_mode()
{
	$ssh $rmc_a "echo 111111 | sudo -S /var/www/set_single_rmc_mode.sh; sleep 5"
	$ssh $rmc_b "echo 111111 | sudo -S /var/www/set_single_rmc_mode.sh; sleep 5"
	#TODO determine the flag of single rmc mode
}


update_rmc_sw()
{
	for r in $rmc_a $rmc_b; do
		$rsync $rmc_fw_dir rmc@$r://home/rmc/ 2>> $problem_list || \
			{ printf "Can't put $rmc_fw_dir to $r\n" | tee -a $update_process_log; continue; }
		$ssh $r "cd /home/rmc/rmc.v$rmc_sw_ver; screen -d -m -S rmc_update echo 111111 | sudo -S rsync -avP /home/rmc/rmc.v$rmc_sw_ver/www /var/; export PGPASSWORD=\"superuser\"; dropdb -U postgres dbRMC; createdb -U postgres dbRMC; psql -f /home/rmc/rmc.v$rmc_sw_ver/dbRMC.v* dbRMC postgres"
		$ssh $r "echo 111111 | sudo -S locale-gen ru_RU.UTF-8; sudo locale-gen en_US.UTF-8;"
	done
}

sync_clock()
{
		$ssh $1 "echo $rmc_user_pass | sudo -S cp /usr/share/zoneinfo/Europe/Moscow /etc/localtime; echo $rmc_user_pass | sudo -S date +%s -s @$(date +%s); echo $rmc_user_pass | sudo -S hwclock --systohc"
		#TODO: Check seting SEL time
		$ssh $1 "ipmitool -H 192.168.1.10 -I lanplus -U admin -P password sel time set \"$(date +"%m/%d/%Y %H:%M:%S")\" >/dev/null 2>&1"
}

check_rack_health()
{
	$ssh $rmc_a "export PGPASSWORD=\"superuser\"; psql -t -U postgres -c 'select \"RMC A Heartbeat\", \"RMC B Heartbeat\", \"Process mode\", \"Side ID\" from \"tdRMCStatus\";' dbRMC 2>/dev/null" | sed "/^$/d;s/ *//g;s/^/$rmc_a: /p" | tee -a $rack_health_list

	$ssh $rmc_b "grep MSK-4 /etc/localtime >/dev/null 2>&1" || { printf "$rmc_a: timezone is not MSK\n" | tee -a $problem_list; sync_clock $rmc_a; sync_clock $rmc_b; }
	local_date=$(date +%s)
	rmc_date=$($ssh $rmc_a "date +%s")
	[ "$((local_date - rmc_date))" -gt "60" ] && { printf "$rmc_a: time offset is greater than one minute!\n" | tee -a $problem_list; sync_clock $rmc_a; sync_clock $rmc_b; }
}

rmc_get_net_config()
{
    eth0_activity=$($ssh $1 "cat /sys/class/net/eth0/carrier 2>/dev/null")
    eth1_activity=$($ssh $1 "cat /sys/class/net/eth1/carrier 2>/dev/null")
    eth0_ip=$($ssh $1 "ifconfig eth0 | sed -n 's/.*inet addr:\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p'")
    eth1_ip=$($ssh $1 "ifconfig eth1 | sed -n 's/.*inet addr:\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p'")
    for i in $eth0_ip $eth1_ip; do
      [ "$i" = "192.168.1.1" ] && { [ $(printf $1 | grep -o -E '[aA].rmm') ] || printf "$1 is not A\n" | tee -a $problem_list; }
      eth0_mac=$($ssh $1 ifconfig eth0 | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | tr -d ':' | tr '[[:lower:]]' '[[:upper:]]')
      eth1_mac=$($ssh $1 ifconfig eth1 | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}' | tr -d ':' | tr '[[:lower:]]' '[[:upper:]]')
    done
    bmc_mac=$($ssh $1 "echo 111111 | sudo -S ipmitool lan print 2>/dev/null | sed -n 's/.*MAC Address.*: \(.*\)/\1/p' | tr -d ':' | tr '[[:lower:]]' '[[:upper:]]'")
    printf "$1: $bmc_mac; eth0 $([ -n "$eth0_activity" ] && printf active) $eth0_ip $eth0_mac; eth1 $([ -n "$eth1_activity" ] && printf active) $eth1_ip $eth1_mac\n"
}   



check_availability()
{
	rmc_a="$1"
	[ -z "$2" ] && rmc_b="$(printf $1 | sed -e 's/\(.*\)[aA].rmm\(.*\)/\1B.rmm\2/')"
	processing_rack=$(printf $1 | grep -o -E '([[:xdigit:]]{1}-){3}[[:xdigit:]]{1,2}')
	
	if ping6 -q -c 1 $1  >/dev/null 2>&1; then
			rmc_get_net_config $1
		elif ping6 -q -c 1 $rmc_b  >/dev/null 2>&1; then
			printf "$1 unreachable\n"
			$rsync ./get-config rmc@$rmc_b://home/rmc/
			$ssh $rmc_b "sh ./get-config 192.168.1.1"
			rmc_get_net_config $rmc_b
		else
		printf "Both unreachable: $processing_rack\n" | tee -a $problem_list
	fi

#	if ping -q -c 1 $1 2>&1> /dev/null; then
#		#TODO: Before all just collect the information; all logic mast be local
#		$ssh $1 "for i in $(ls -1 /sys/class/net/|grep -v lo ); do \
#				[ "$(cat /sys/class/net/$i/carrier 2>/dev/null)" == "1" ]; && \
#					nic_ip=$(ifconfig $i | sed -n 's/.*inet addr:\([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*\).*/\1/p') \
#					[ "$nic_ip" = "192.168.1.1" ] &&\
#						[ $(printf $1 | grep -o -E '[aA].rmm') ] || printf "$1 is not A"; done | tee -a $problem_list
#		nic0_mac=$(ifconfig eth0 | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}')
#		done
#
#		BMC_MAC="$(ipmitool lan print 2>/dev/null|sed -n 's/.*MAC Address.*: \(.*\)/\1/p')"
#		printf "Both unreachable: $(printf "$processing_rack")" | tee -a $problem_list
#	fi
}

reboot_rmcs()
{
	wait $1 $2 || printf "$rmc_a: filed to upgrade RMC of FSCB\n" | tee -a $problem_list
	$ssh $rmc_a "echo 111111 | sudo -S reboot" || printf "$rmc_a: couldn't reboot the RMC after successfull upgrade\n"
	$ssh $rmc_b "echo 111111 | sudo -S reboot" || printf "$rmc_b: couldn't reboot the RMC after successfull upgrade\n"
}

for FQDN in $rmcs_list; do
		rmc_a="$FQDN.ipmi.yandex-team.ru"
		if ping6 -q -c 1 $rmc_a 2>&1 > /dev/null ; then
			ssh="timeout 60 sshpass -p $rmc_user_pass ssh -n -o ConnectTimeout=60 -o StrictHostKeyChecking=no -l rmc"
			#rsync="sshpass -p $rmc_user_pass rsync -avP -e \"ssh -o StrictHostKeyChecking=no\""
			rsync="timeout 360 sshpass -p $rmc_user_pass scp -r"
			rmc_b="$(printf "$rmc_a" | sed -e 's/\(.*\)[aA].rmm\(.*\)/\1B.rmm\2/')"
				[ -z "$rmc_sw_only" -a -z "$check_health" ] && [ -n "$opt_flash" ] && update_fsc_bmc &
				update_fsc_pid=$!
				[ -n "$update_fsc_pid" ] && printf "$update_fsc_pid " >> $update_fsc_pid_file
				[ -n "$check_health" ] && { check_rack_health & \
						printf "$! " >> $update_rmc_pid_file; }
				[ -z "$opt_flash" ] && { check_fcs_fw_ver & \
						printf "$! " >> $update_rmc_pid_file; }
				[ -z "$opt_flash" ] && { check_rmc_sw_ver $rmc_a & \
						printf "$! " >> $update_rmc_pid_file; }
				[ -z "$opt_flash" ] && { check_rmc_sw_ver $rmc_b & \
						printf "$! " >> $update_rmc_pid_file; }

			if ping6 -q -c 1 $rmc_b 2>&1 > /dev/null ; then 
				if [ -z "$check_health" -a -n "$opt_flash" ]; then
					check_rmc_sw_ver $rmc_a || rmc_a_status=$?
					check_rmc_sw_ver $rmc_b || rmc_b_status=$?
					if [ -n "$rmc_a_status" -o -n "$rmc_b_status" ]; then
						set_rmcs_single_mode 
				 		update_rmc_sw &
						update_rmc_pid=$!
						printf "$update_rmc_pid " >> $update_rmc_pid_file
					fi
				fi
			else
				printf "$rmc_b unreachable\n" | tee -a $unreachable_rmcs
				#TODO Try to check or reboot rmc_b from rmc_a
				#check_availability $rmc_a $rmc_b 
			fi
		else
			#check_availability $rmc_b $rmc_a 
			printf "$rmc_a unreachable\n" | tee -a $unreachable_rmcs
		fi
		wait $update_rmc_pid $update_fsc_pid && reboot_rmcs $update_fsc_pid $update_rmc_pid &
done

wait $([ -s "$update_rmc_pid_file" ] && cat $update_rmc_pid_file) $([ -s "$update_fsc_pid_file" ] && cat $update_fsc_pid_file)||:
