#!/bin/bash 
#-------------------------------------------------------------------------------
# Skript        : check_hmc_by_ssh.sh
# Description   : Checks state of a HMC or of its managed systems
#
# Read the help instructions for more information
#-------------------------------------------------------------------------------
# Copyright (c) 2013 PROFI AG, Martin Rueckert (m.rueckert@profi-ag.de)
# Copyright (c) 2018 PROFI AG, Dominik Keil (d.keil@profi-ag.de)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Nagios is a registered trademarks of Ethan Galstad.
#-------------------------------------------------------------------------------
# CONTRIBUTION
# Suggestions and/or corrections for improvement are welcome and can be sent to
# PROFI_monitoring@profi-ag.de
#
# If you submit any modifications, corrections or enhancements to this work,
# or any other work intended for use with this Software, to PROFI AG, you
# confirm that you are the copyright holder for those contributions and you
# grant PROFI AG a nonexclusive, worldwide, irrevocable, royalty-free,
# perpetual, license to use, copy, create derivative works based on those
# contributions, and sublicense and distribute those contributions and any
# derivatives thereof.
#
# This will not limit the rights granted to you to modify and distribute this
# software under the terms of the GPL.
#-------------------------------------------------------------------------------
#
# Change Log
# 1.0   2013-11-23 - Martin Rueckert (m.rueckert@profi-ag.de)
#        Initial revision
# 1.1   2014-01-20 - Martin Rueckert (m.rueckert@profi-ag.de)
#        Added Exclude-Option and some minor changes
# 1.2   2015-02-23 - Martin Rueckert (m.rueckert@profi-ag.de)
#        LPARRUN: Added additional informations about assigned CPUs & Mem
# 1.3   2018-01-05 - Dominik Keil (d.keil@profi-ag.de)
#        Adding parameter for providing an arbitrary SSH key
#        Adding parameter for providing an arbitrary SSH username
#-------------------------------------------------------------------------------
PROGNAME="check_hmc_by_ssh.sh"
VERSION="1.3"

# Variables (Part 1)
debug=0
nagiosPerfdata=""
exitCode=0		# OK
OUTPUT=""
WARN=""
CRIT=""
EXCLUDE=""
avgRTT=0

# constants
STATUS=(OK WARNING CRITICAL UNKNOWN)	# Nagios exit states 0, 1, 2, 3

################################################################################
# SUBFUNCTIONS
################################################################################

print_usage() {
cat <<EOFUSAGE
$PROGNAME  (Version $VERSION)
----------------------------------
Usage: $PROGNAME ( -I <IP-ADDRESS> | -1 <IP-ADDRESS> -2 <IP-ADDRESS> ) -C <CHECKTYPE> [-A <ATTRIBUTE>] [-w <WARN> ] [-c <CRIT>] [-h]
EOFUSAGE
}

print_help() {
print_usage
cat <<EOFHELP

    -h    Shows this help
    -i    path to non-default SSH private key
    -u    username to log in with
    -I    IP Address of HMC
    -1    IP Address of first HMC
    -2    IP Address of second HMC
    -C    Check Type, possible arguments:
             OVERVIEW    Lists managed machines and LPAR - no checks, helpful for check setup
             HMCDISKS    Check disk usage on HMC  (alert if usage > 85% / 92%)
             HMCMEM      Check memory usage of HMC
             HMCSWAP     Check swap usage of HMC
	     HMCCPU      Check cpu usage of HMC
             HMCUPTIME   Check uptime of HMC 
             LEDSTATUS   Check led status of managed systems (See paragraph 'Multihosts' below)
             HWEVENTS    Check open hardware events (See paragraph 'Multihosts' below)
             SYSOPER     Check if SYSTEM is operating (See paragraph 'Multihosts' below)
             LPARRUN     Check if LPAR runs (See paragraph 'Multihosts' below)
	     LPARCONC    Checks if two LPARS/SYSTEM (one of them should be only cold standby)
	                  runs concurrent (See paragraph 'Multihosts' below)
             LPARCPU     Checks the CPU utilization of all LPARs on System (Information only)
	                  HINT: You have to enable the collection of utilization data on each
			        HMC by "chlparutil -r config -s 300"!
    -A    Attribute for check types wich requires attributes:
              SYSOPER   :  System name (use OVERVIEW for implementation)
              LPARRUN   :  LPAR name (use OVERVIEW for implementation)
              LPARCONC  :  Two comma separated LPAR or System Names
	      LPARCPU   :  System name (use OVERVIEW for implementation)
    -E    Exclude attribute for check 'LEDSTATUS': Name of LPAR (or comma separated list of
           LPAR names), which should be excluded from the LED-check.
	   HINT: Using this option will suppress any alarm regarding the phys. LED !
    -w    Overwrite default WARNING threshold (see hint below)
    -c    Overwrite default CRITICAL threshold (see hint below)
            Hint: Thresholds takes effect only on following check types
                  Default values, relational operator, unit: (WARN/CRIT/OPERATOR/UNIT)
	     HMCDISKS    (85/92/>/%)
	     HMCMEM      (90/95/>/%)
             HMCSWAP     (20/60/>/%)
	     HMCCPU      (101/102/>/%)   just for measurement
	     HMCUPTIME   (-/1800/</seconds)

Multihost Queries
    If you have two redundant HMCs (best practice), which can manage all pSeries in your
    environment, some of the above listed queries can be answered by each of them.
    In this case you can use the Options -1 AND -2 to ask only one of them. This script
    will then check if the first IP address is reachable and if so, it will ask only this
    HMC. If not, the second HMC will be asked.
    This affects the Check LEDSTATUS, HWEVENTS, SYSOPER, LPARRUN, LPARCONC
    
    The Option -I cannot be used with -1 and -2.

EOFHELP
}

compare_thresholds() {
if [ $WARN -ge $CRIT ] ; then
	echo -e "ERROR: Warning threshold '$WARN' must be lower than critical threshold '$CRIT'. See help\n"
	print_usage
	exit 3		# UNKNOWN
fi
}

# FUNCTION
function filterObj {
	IFS=',' read -a objFilterArray <<< "$ATTRIBUTE"
	Fmax=${#objFilterArray[@]}
	exitFilter=0
	for (( j=0; j<$Fmax ; j++ ));
	do
		if [ "$1" = "${objFilterArray[$j]}" ]; then
			exitFilter=1
		fi
	done
	return $exitFilter
}
#
################################################################################


################################################################################
# GET ARGUMENTS, CHECK THEM AND EVALUATE
################################################################################

SSHUSER=""
# get arguments
while getopts 'hdi:u:I:1:2:C:A:w:c:E:' OPT; do
  case $OPT in
    h)  print_help
        exit 0;;
    d)  debug=1;;
    i)  if [ -e $OPTARG ]; then SSHPRIVKEY="-i $OPTARG"; else SSHPRIVKEY=""; fi;;
    u)  SSHUSER="${OPTARG}@";;
    I)  machine=$OPTARG;;
    1)  machine1=$OPTARG;;
    2)  machine2=$OPTARG;;
    C)  checkType=$OPTARG;;
    A)  ATTRIBUTE=$OPTARG;;
    w)  WARN=$OPTARG;;
    c)  CRIT=$OPTARG;;
    E)  EXCLUDE=$OPTARG
        EXCLUDEwarning=" [FYI: Alarms for LPAR(s) $EXCLUDE are excluded, so for phys. LED too!]";;
    *)  echo "ERROR: Unknown argument \"$OPT\" ! Read the help"
        print_usage
	exit 3;;	# UNKNOWN
  esac
done

# precheck of arguments
if [ -z "$checkType" ] ; then
        echo "ERROR: Missing arguments. Read the help"
	print_usage
	exit 3		# UNKNOWN
elif ([[ -n "$machine" ]]) && ([[ -n "$machine1" ]] || [[ -n "$machine2" ]]) ; then
	echo "ERROR: If you use option -I you can't use options -1 or -2. Read the help"
	print_usage
	exit 3		# UNKNOWN
elif [ -z "$machine" ] ; then
	if [ -z "$machine1" -a -z "$machine2" ] ; then
		echo "ERROR: Missing any IP address of HMC(s). Read the help"
		print_usage
		exit 3		# UNKNOWN
	elif [ -z "$machine1" -o -z "$machine2" ] ; then
		echo "ERROR: If you use options -1 or -2 you have to use both. Read the help"
		print_usage
		exit 3		# UNKNOWN
	fi
fi

# set default thresholds
if [ -n "$WARN" -o -n "$CRIT" ] ; then		# if any threshold is given. If only one, then set the other one default
	if [ "$checkType" = "HMCDISKS" ] ; then
		[ -z "$WARN" ] && WARN=85
		[ -z "$CRIT" ] && CRIT=92
		compare_thresholds
	elif [ "$checkType" = "HMCMEM" ] ; then
		[ -z "$WARN" ] && WARN=90
		[ -z "$CRIT" ] && CRIT=95
		compare_thresholds
	elif [ "$checkType" = "HMCSWAP" ] ; then
		[ -z "$WARN" ] && WARN=20
		[ -z "$CRIT" ] && CRIT=60
		compare_thresholds
	elif [ "$checkType" = "HMCCPU" ] ; then
		[ -z "$WARN" ] && WARN=101
		[ -z "$CRIT" ] && CRIT=102
		compare_thresholds
	elif [ "$checkType" = "HMCUPTIME" ] ; then
		# WARNING: Threshold for WARNING won't take effect for this check type. See help
		[ -z "$CRIT" ] && CRIT=1800
	fi
fi

case $checkType in
	HMCDISKS)
			WARNthreshold=${WARN:-85}
			CRITthreshold=${CRIT:-92};;
	HMCMEM)
			WARNthreshold=${WARN:-90}
			CRITthreshold=${CRIT:-95};;
	HMCSWAP)
			WARNthreshold=${WARN:-20}
			CRITthreshold=${CRIT:-60};;
	HMCCPU)
			WARNthreshold=${WARN:-101}
			CRITthreshold=${CRIT:-102};;
	HMCUPTIME)
			CRITthreshold=${CRIT:-1800};;
esac

# Variables (Part 2 - need some arguments)
CmdOutFile="/tmp/hmc-check_$machine.$checkType.output"
CmdOutFileSys="/tmp/hmc-check_$machine.$checkType.sys"
CmdOutFileLpar="/tmp/hmc-check_$machine.$checkType.lpar"
ResultOutFile="/tmp/hmc-check_$machine.$checkType.out"

################################################################################
# Multihost query?
################################################################################

if [ -n "$machine1" -a -n "$machine2" ] ; then
	# ping 2 times with timeout of 2 seconds the first ip address:
	ping -c 2 -W 2 $machine1 >/dev/null 2>&1
	if [ $? -eq 0 ] ; then		# ping successful?
		machine=$machine1
	else
		machine=$machine2
	fi
	[ $debug -eq 1 ] && echo "machine=$machine"
fi

################################################################################
# MAIN
################################################################################

case $checkType in
    OVERVIEW)
        counterDown=0
        echo -ne "OVERVIEW from HMC\n\n"
        hmcCommand="lssyscfg -r sys -F name,type_model,serial_num,ipaddr"
        /usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" > $CmdOutFile
        if [ $? -eq 0 ]; then
                systemsList=""
                echo -ne "Managed Server\n"
                while read line
                do
                        IFS=',' read -a ValueArray <<< "${line}"	# set array with Internal Field Separator ','
                        #echo -ne " ${ValueArray[0]} : (IP ${ValueArray[3]} , Type ${ValueArray[1]} , S/N ${ValueArray[2]})\n"
			printf " %-30s : Type %-26s , S/N %8s %s\n" "${ValueArray[0]}" "${ValueArray[1]}" "${ValueArray[2]}" "(IP ${ValueArray[3]})"

                        systemsList="$systemsList ${ValueArray[0]}"
                done < $CmdOutFile
                echo -ne "\n"
                for managedSys in $systemsList
                do
                        hmcCommandL="lssyscfg -r lpar -m $managedSys -F name,lpar_id,state,os_version,logical_serial_num,rmc_ipaddr"
                        /usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL" > $CmdOutFileLpar
                        if [ -s $CmdOutFileLpar ]; then
                                echo -ne "LPARs on $managedSys\n"
                                while read lineL
                                do
                                        IFS=',' read -a ValueArrayL <<< "${lineL}"
                                        if [ "${ValueArrayL[2]}" != "Running" ]; then
                                                counterDown=$(( $counterDown + 1 ))
                                        fi
					RMCIP=""
					[ -n "${ValueArrayL[5]}" ] && RMCIP="(IP ${ValueArrayL[5]})"
					printf " %-10s is %-15s  : ID %s, OS %-23s, S/N %8s %s\n" "${ValueArrayL[0]}" "'${ValueArrayL[2]}'" "${ValueArrayL[1]}" "'${ValueArrayL[3]}'" "${ValueArrayL[4]}" "$RMCIP"
                                done < $CmdOutFileLpar
                                echo -ne "\n"
                        else
                                echo -ne "Error: No lpar found on $managedSys\n"
                        fi
                done
        else
                OUTPUT="ERROR: An error occured when querying HMC: `cat $CmdOutFile`"
                exitCode=3	# UNKNOWN
        fi
    ;;
    HMCDISKS)
        hmcCommand="monhmc -r disk -n 0"
    	# execute and grep only real devices:
        RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" | grep "^/dev/" > $CmdOutFile`
        if [ -s $CmdOutFile ]; then		# file exists and has a size greater than zero
                while read line
                do
                        IFS=' ' read -a ValueArray <<< "${line}"
			usage=`echo ${ValueArray[4]} | cut -f 1 -d %`
			if [ $usage -ge $CRITthreshold ] ; then
				OUTPUT="${OUTPUT} FS ${ValueArray[5]} uses ${ValueArray[4]} (${ValueArray[3]}k/${ValueArray[1]}k free),"
				[ $exitCode -lt 2 ] && exitCode=2	# CRITICAL
			elif [ $usage -ge $WARNthreshold ] ; then
				OUTPUT="${OUTPUT} FS ${ValueArray[5]} uses ${ValueArray[4]} (${ValueArray[3]}k/${ValueArray[1]}k free),"
				[ $exitCode -lt 1 ] && exitCode=1	# WARNING
			else
				OUTPUT2="${OUTPUT2} FS ${ValueArray[5]} uses ${ValueArray[4]},"
			fi
			nagiosPerfdata="${nagiosPerfdata} ${ValueArray[5]}=$usage;$WARNthreshold;$CRITthreshold;0;100"
                done < $CmdOutFile
        else
                OUTPUT="Error: No disks found"
                exitCode=3	# UNKNOWN
        fi
    	[ -z "$OUTPUT" ] && OUTPUT="${OUTPUT2}"
    	OUTPUT="`echo $OUTPUT | sed 's/\,$//'`"
    	OUTPUT="Disk Usage is ${STATUS[exitCode]} - $OUTPUT | ${nagiosPerfdata}"
    ;;
    HMCUPTIME)
        hmcCommand="cat /proc/uptime"
	
        uptimehmc=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" | cut -f 1 -d .`
        if (( $uptimehmc < $CRITthreshold )); then
                exitCode=2	# CRITICAL
        fi
    	OUTPUT="UpTime HMC is ${STATUS[exitCode]} - System is UP since ${uptimehmc}s (Alert if uptime < ${CRITthreshold}s) | uptime=$uptimehmc;;$CRITthreshold;;"
    ;;
    HMCMEM)
        hmcCommand="monhmc -r mem -n 0"
	
        RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand"`
    	#Example output: "Mem:   4095732k total,  2989948k used,  1105784k free,   445448k buffers"
	memTotl=`echo $RESULT | cut -d ' ' -f2 | sed 's/k$//'`
	memUsed=`echo $RESULT | cut -d ' ' -f4 | sed 's/k$//'`
	MEMusage=`expr \`expr $memUsed \* 100\` / $memTotl`
        if (( $MEMusage >= $CRITthreshold )); then
                exitCode=2	# CRITICAL
	elif (( $MEMusage >= $WARNthreshold )); then
		exitCode=1	# WARNING
        fi
    	OUTPUT="MemoryUsage of HMC is ${STATUS[exitCode]} - MemUsage = ${MEMusage}% | MEMusage=$MEMusage;$WARNthreshold;$CRITthreshold;;"
    ;;
    HMCSWAP)
        hmcCommand="monhmc -r swap -n 0"
	
        RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand"`
    	#Example output: "Swap:  2040244k total,    42836k used,  1997408k free,  1808320k cached"
	swapTotl=`echo $RESULT | cut -d ' ' -f2 | sed 's/k$//'`
	swapUsed=`echo $RESULT | cut -d ' ' -f4 | sed 's/k$//'`
	SWAPusage=`expr \`expr $swapUsed \* 100\` / $swapTotl`
        if (( $SWAPusage >= $CRITthreshold )); then
                exitCode=2	# CRITICAL
	elif (( $SWAPusage >= $WARNthreshold )); then
		exitCode=1	# WARNING
        fi
    	OUTPUT="SwapUsage of HMC is ${STATUS[exitCode]} - SwapUsage = ${SWAPusage}% | SWAPusage=$SWAPusage;$WARNthreshold;$CRITthreshold;;"
    ;;
    HMCCPU)
	RESULT=0
	MINidle=100
        hmcCommand="monhmc -r proc -n 0"
	
    	#Example output (maybe several lines):
	#"Cpu0  :  0.0%us,  0.0%sy,  0.0%ni,100.0%id,  0.0%wa,  0.0%hi,  0.0%si,  0.0%st"
	#"Cpu1  :  0.3%us,  0.3%sy,  0.0%ni, 99.3%id,  0.0%wa,  0.0%hi,  0.0%si,  0.0%st"
	
	# cut only idel values and put them in an array:
        ValueArray=(`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" | cut -d\, -f4 | sed 's/\%id//g ; s/ //g' | tr "\n" " "`)
	NUMprocs=${#ValueArray[*]}
	for ((i=0; i<$NUMprocs; i++))
	do
		RESULT=`echo "scale=2 ; ${RESULT}+${ValueArray[$i]}" | bc`		# add all idle values
		# get lowest idle value:
		[ `echo ${ValueArray[$i]} | cut -d. -f1` -lt `echo $MINidle | cut -d. -f1` ] && MINidle=${ValueArray[$i]}
	done
	RESULT=`echo "scale=2 ; ${RESULT}/$NUMprocs" | bc`	# devide sum by number of values
	CPUusage=`echo "scale=2 ; 100-${RESULT}" | bc`		# calc (average) cpu usage
	CPUmax=`echo "scale=2 ; 100-${MINidle}" | bc`		# calc highest cpu usage
	CPUusageINT=`echo $CPUusage| cut -d. -f1`		# convert into integer (for comparison)
        if (( $CPUusageINT >= $CRITthreshold )); then
                exitCode=2	# CRITICAL
	elif (( $CPUusageINT >= $WARNthreshold )); then
		exitCode=1	# WARNING
        fi
    	OUTPUT="CPUusage of HMC is ${STATUS[exitCode]} - CPUusage = ${CPUusage}% (average of $NUMprocs CPU cores), highest CPUusage: ${CPUmax}% | CPUusage=${CPUusage}%;$WARNthreshold;$CRITthreshold;0;100 CPUmax=${CPUmax}%;;;0;100"
    ;;
    LEDSTATUS)
    	counterON=0
    	VcounterON=0
	sectionline="------------------------------------------------------------"

	hmcCommand="lssyscfg -r sys -F name"
	/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" > $CmdOutFile
	if [ $? -eq 0 ]; then
		systemsList="`cat $CmdOutFile | tr '\n' ' '`"
		
		for managedSys in $systemsList
		do
    			hmcCommandL="lsled -r sa -m ${managedSys} -t"
    			
    			RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL phys"`
    			PhysLED="off"
    			if [ -n "`echo $RESULT | grep 'state=on'`" ] ; then
    				[ -z "$EXCLUDE" ] && counterON=$(( $counterON + 1 ))
    				PhysLED="ON !!!"
    				OUTPUT="${OUTPUT} Physical SA LED of \"${managedSys}\" is ON,"
    			fi
			NameLen=`echo ${managedSys} | awk '{print length($1)}'`
			RestLen=`expr 44 - $NameLen`
    			printf "\n--- Managed System: %s %-.${RestLen}s\n" ${managedSys} $sectionline >> $ResultOutFile
    
    			RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL virtualsys"`
    			VirtLED="off"
    			if [ -n "`echo $RESULT | grep 'state=on'`" ] ; then
    				VirtLED="ON !!!"
    				OUTPUT="${OUTPUT} Virtual SA LED of \"${managedSys}\" is ON,"
    			fi
    			echo " -> Physical SA LED = $PhysLED  |  Virtual SA LED = $VirtLED" >> $ResultOutFile
    			
			echo -e "\nVirtual partition SA LEDs:" >> $ResultOutFile
    			RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL virtuallpar" >> $CmdOutFileSys`
    			while read line2
    			do
    				IFS=',' read -a LparArray <<< "${line2}"
    				lparID=`echo ${LparArray[0]} | cut -d= -f2`
    				lparNAME=`echo ${LparArray[1]} | cut -d= -f2`
    				LparLED="off"
    				if [ -n "`echo ${LparArray[2]} | grep 'state=on'`" ] ; then
    					[ -z "`echo $EXCLUDE | grep $lparNAME`" ] && VcounterON=$(( $VcounterON + 1 ))
    					LparLED="ON    !!!"
    					OUTPUT="${OUTPUT} Virtual partition SA LED of LPAR \"$lparNAME\" (ID $lparID) is ON,"
    				fi
    				printf " %-40s : %s\n" "LPAR (ID $lparID) \"$lparNAME\"" "$LparLED" >> $ResultOutFile
    			done < $CmdOutFileSys
    			rm $CmdOutFileSys
                done
    		if [ $counterON -gt 0 -o $VcounterON -gt 0 ] ; then
    			exitCode=1	# WARNING
    		else
    			OUTPUT="All LEDs are OFF"
    		fi
        else
		OUTPUT="An error occured when querying HMC: `cat $CmdOutFile`"
		exitCode=3	# UNKNOWN
        fi
    	OUTPUT="`echo $OUTPUT | sed 's/\,$//'`"		# delete a comma at end of line (if it exists)
    	OUTPUT="LED status ${STATUS[exitCode]} - ${OUTPUT}${EXCLUDEwarning} | physLEDon=$counterON;1;;0; virlLEDon=$VcounterON;1;;0; `cat $ResultOutFile`"
    ;;
    HWEVENTS)
        numevents=0
        hmcCommand="lssvcevents -t hardware --filter status=open"
	echo -e "\n" > $ResultOutFile
	# get events and format output (additional nl after each entry, nl for each ','
	/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" | sed 's/$/\n/g ; s/\,/\n/g' >> $ResultOutFile
	exitstatus=$?
	numevents=`cat $ResultOutFile | grep "^problem_num" | wc -l`
        if [ $exitstatus -gt 0] ; then
                OUTPUT="An error occured when quering HMC"
                exitCode=3					# UNKNOWN
        else
		if [ $numevents -gt 0 ] ; then
			exitCode=1				# WARNING
			OUTPUT="$numevents events are open!"
		else
			OUTPUT="No hardware event found"	# OK
		fi
        fi
        OUTPUT="Hardware Events are ${STATUS[exitCode]} - $OUTPUT | numevents=$numevents;1;;0; `cat $ResultOutFile`"
    ;;
    SYSOPER)
    	if [ -z $ATTRIBUTE ]; then
    		echo -e "ERROR: Miss the System name.\n"
    		exitCode=3	# UNKNOWN
    	else
		hmcCommand="lssyscfg -r sys -F name,state,serial_num,ipaddr"
		/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" > $CmdOutFile
		if [ $? -eq 0 ]; then
			RESULT=`cat $CmdOutFile | grep "$ATTRIBUTE"`
			if [ -n "$RESULT" ] ; then
				IFS=',' read -a ValueArray <<< "${RESULT}"
				OUTPUT="${ValueArray[0]} is ${ValueArray[1]} (S/N ${ValueArray[2]}, IP '${ValueArray[3]}')"
				avgRTT=`ssh $SSHPRIVKEY ${SSHUSER}${machine} "ping ${ValueArray[3]} -c 3" | tail -n 1 | cut -d/ -f5`
			else
				OUTPUT="No information about System available! HMC output: `cat $CmdOutFile`"
				exitCode=3	# UNKNOWN
			fi
			if [ "${ValueArray[1]}" != "Operating" ]; then
				exitCode=2	# CRITICAL
			fi
		else
			OUTPUT="An error occured when querying HMC: `cat $CmdOutFile`"
			exitCode=3	# UNKNOWN
		fi
	fi
        OUTPUT="Status System '$ATTRIBUTE' is ${STATUS[exitCode]} - $OUTPUT | rta=${avgRTT}s;;;;"
    ;;
    LPARRUN)
    	if [ -z $ATTRIBUTE ]; then
    		echo -e "ERROR: Miss the LAPR name.\n"
    		exitCode=3	# UNKNOWN
    	else
		hmcCommand="lssyscfg -r sys -F name"
		/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" > $CmdOutFile
		if [ $? -eq 0 ]; then
			systemsList="`cat $CmdOutFile | tr '\n' ' '`"
			
			for managedSys in $systemsList
			do
				hmcCommandL="lssyscfg -r lpar -m $managedSys -F name,lpar_id,state,os_version --filter \"lpar_names=$ATTRIBUTE\""
				RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL"`
				IFS=',' read -a ValueArray <<< "${RESULT}"
				if [ "${ValueArray[0]}" = "$ATTRIBUTE" ]; then	# System found? (could be an error message as well)
					if [ "${ValueArray[2]}" != "Running" ]; then
						exitCode=2	# CRITICAL
					fi
					OUTPUT="${ValueArray[0]} is ${ValueArray[2]} (ID ${ValueArray[1]}, OS '${ValueArray[3]}')"
					
					# Get some additional informations:
					hmcCommandL="lshwres -r proc -m $managedSys --level lpar --filter \"lpar_names=$ATTRIBUTE\" -F lpar_id,curr_min_proc_units,curr_proc_units,curr_max_proc_units"
					RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL"`
					IFS=',' read -a CpuArray <<< "${RESULT}"
					OUTPUT="$OUTPUT\ncurr_min_proc_units=${CpuArray[1]}, curr_proc_units=${CpuArray[2]}, curr_max_proc_units=${CpuArray[3]}"
					
					hmcCommandL="lshwres -r mem -m $managedSys --level lpar --filter \"lpar_names=$ATTRIBUTE\" -F lpar_id,curr_min_mem,curr_mem,curr_max_mem"
					RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL"`
					IFS=',' read -a MemArray <<< "${RESULT}"
					CURR_MIN_MEM=`expr ${MemArray[1]} \/ 1024`
					CURR_MEM=`expr ${MemArray[2]} \/ 1024`
					CURR_MAX_MEM=`expr ${MemArray[3]} \/ 1024`
					OUTPUT="$OUTPUT\ncurr_min_mem=${CURR_MIN_MEM}GiB, curr_mem=${CURR_MEM}GiB, curr_max_mem=${CURR_MAX_MEM}GiB"
					OUTPUT="$OUTPUT\n|min_proc_units=${CpuArray[1]};;;; proc_units=${CpuArray[2]};;;; max_proc_units=${CpuArray[3]};;;;"
					OUTPUT="$OUTPUT min_mem=${CURR_MIN_MEM}GiB;;;; curr_mem=${CURR_MEM}GiB,;;;; max_mem=${CURR_MAX_MEM}GiB;;;;"
					break		# exit for loop
				fi
			done
		else
			OUTPUT="An error occured when querying HMC: `cat $CmdOutFile`"
			exitCode=3	# UNKNOWN
		fi
	fi
        OUTPUT="Status LPAR '$ATTRIBUTE' is ${STATUS[exitCode]} - $OUTPUT"
    ;;
    LPARCONC)
    	if [ -z $ATTRIBUTE ]; then
    		echo -e "ERROR: Miss the LAPR names. See help\n"
    		exitCode=3	# UNKNOWN
	elif [[ "$ATTRIBUTE" != *,* ]] ; then		# attribute contains not a comma?
		echo -e "ERROR: Two comma separated LAPR/System names required. See help\n"
		exitCode=3	# UNKNOWN
    	else
		LPARlist="`echo ${ATTRIBUTE} | tr ',' ' '`"

		hmcCommand="lssyscfg -r sys -F name"
		/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommand" > $CmdOutFile
		if [ $? -eq 0 ]; then
			systemsList="`cat $CmdOutFile | tr '\n' ' '`"
			RUNsum=0
			
			for LPAR in $LPARlist
			do
				for managedSys in $systemsList
				do
					hmcCommandL="lssyscfg -r lpar -m $managedSys -F name,state --filter \"lpar_names=$LPAR\""
					RESULT=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$hmcCommandL"`
					IFS=',' read -a ValueArray <<< "${RESULT}"
					if [ "${ValueArray[0]}" = "$LPAR" ]; then	# System found? (could be an error message as well)
						if [ "${ValueArray[1]}" = "Running" ]; then
							RUNsum=`expr $RUNsum + 1`
							LPARrunning="${ValueArray[0]}"
						fi
						OUTPUT="${OUTPUT} ${ValueArray[0]} is ${ValueArray[1]},"
					fi
				done
			done
			OUTPUT="`echo $OUTPUT | sed 's/\,$//'`"		# delete a comma at end of line (if it exists)
			
			# evaluation:
			if [ $RUNsum -gt 1 ] ; then
				OUTPUT="BOTH LPARs are running conccurent !!! (${OUTPUT})"
				exitCode=2	# CRITICAL
			elif [ $RUNsum -eq 0 ] ; then
				OUTPUT="No one of the two LPARs is running. (${OUTPUT})"
			else
				OUTPUT="Only LPARs $LPARrunning is running. (${OUTPUT})"
			fi
		else
			OUTPUT="ERROR: An error occured when querying HMC: `cat $CmdOutFile`"
			exitCode=3	# UNKNOWN
		fi
	fi
        OUTPUT="Conccurent status LPARs $LPARlist is ${STATUS[exitCode]} - $OUTPUT"
    ;;
    LPARCPU)
        if [ -z $ATTRIBUTE ]; then
    		echo -e "ERROR: Miss the System name.\n"
    		exitCode=3	# UNKNOWN
        else
                mycommandL="lssyscfg -r lpar -m $ATTRIBUTE -F lpar_id"
                myresult=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$mycommandL" > $CmdOutFileLpar`
                if [ $? -eq 0 ]; then
                        LparIDs=`cat $CmdOutFileLpar | tr '\n' ' '`
                        for LparID in $LparIDs
                        do
                                IFS=',' read -a variablesArrayL <<< "${lineL}"

                                mycommandT="lshwres -r proc -m $ATTRIBUTE --level lpar -F curr_proc_mode,curr_proc_units --filter lpar_ids=$LparID"
                                tmp_output=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$mycommandT"`
                                IFS=',' read -a tmpArray <<< "$tmp_output"
                                curr_proc_mode="${tmpArray[0]}"
                                curr_proc_units="${tmpArray[1]}"

                                mycommand="lslparutil -m $ATTRIBUTE -r lpar -F time,lpar_id,capped_cycles,uncapped_cycles,entitled_cycles,idle_cycles,time_cycles,lpar_name --filter lpar_ids=$LparID -n 11"
                                myresult=`/usr/bin/ssh $SSHPRIVKEY ${SSHUSER}${machine} "$mycommand" > $CmdOutFile`
                                if [ -s $CmdOutFile ]; then
                                        firstLine=`head -n 1 $CmdOutFile`
                                        secondLine=`tail -n 1 $CmdOutFile`
                                        IFS=',' read -a firstArray <<< "$firstLine"
                                        f_time="${firstArray[0]}"
                                        f_lpar_id="${firstArray[1]}"
                                        f_capped_cycles="${firstArray[2]}"
                                        f_uncapped_cycles="${firstArray[3]}"
                                        f_entitled_cycles="${firstArray[4]}"
                                        f_idle_cycles="${firstArray[5]}"
                                        f_time_cycles="${firstArray[6]}"

                                        IFS=',' read -a secondArray <<< "$secondLine"
                                        s_time="${secondArray[0]}"
                                        s_lpar_id="${secondArray[1]}"
                                        s_capped_cycles="${secondArray[2]}"
                                        s_uncapped_cycles="${secondArray[3]}"
                                        s_entitled_cycles="${secondArray[4]}"
                                        s_idle_cycles="${secondArray[5]}"
                                        s_time_cycles="${secondArray[6]}"
                                        lpar_name="${secondArray[7]}"

                                        sharedProc="((($f_capped_cycles - $s_capped_cycles) + ($f_uncapped_cycles - $s_uncapped_cycles)) / ($f_entitled_cycles - $s_entitled_cycles)) * 100"
                                        sharedProcUnit="(($f_capped_cycles - $s_capped_cycles) + ($f_uncapped_cycles - $s_uncapped_cycles)) / ($f_time_cycles - $s_time_cycles)"
                                        #dedicatedProc="((($f_capped_cycles - $s_capped_cycles) - ($f_idle_cycles - $s_idle_cycles)) / ($f_capped_cycles - $s_capped_cycles)) * 100"
                                        #dedicatedProcUnit="(($f_pped_cycles - $s_capped_cycles) - ($f_idle_cycles - $s_idle_cycles)) / ($f_time_cycles - $s_time_cycles)"
                                        sharedProc=`echo "scale=5 ; $sharedProc" | bc -l`
                                        sharedProcUnit=`echo "scale=5 ; $sharedProcUnit" | bc -l`
                                        #dedicatedProc=`echo "$dedicatedProc" | bc -l`
                                        #dedicatedProcUnit=`echo "$dedicatedProcUnit" | bc -l`
                                        [ -n "`echo $sharedProcUnit | grep '^\.'`" ] && sharedProcUnit="0${sharedProcUnit}"
                                        [ -n "`echo $sharedProc | grep '^\.'`" ] && sharedProc="0${sharedProc}"

                                        echo -ne "CPU on $lpar_name [Updated: $f_time]\n" >> $ResultOutFile
                                        echo -ne "Entitled processor cores $curr_proc_units - Mode: $curr_proc_mode\n" >> $ResultOutFile
                                        echo -ne "Share Processor Unit Utilized = $sharedProcUnit\n" >> $ResultOutFile
                                        echo -ne "Share Processor Utilization % = $sharedProc\n.\n" >> $ResultOutFile
                                        #echo -ne "Dedicated Processor Unit Utilized = $dedicatedProcUnit\n"
                                        #echo -ne "Dedicated Processor Utilization % = $dedicatedProc\n\n"

                                        nagiosPerfdata="$nagiosPerfdata CPU_%_$lpar_name=$sharedProc;;;0;100 CPU_$lpar_name=$sharedProcUnit;;;0;$curr_proc_units"

                                else
                                        echo -ne "Error with access to $CmdOutFile\n"
                                        exitCode=3	# UNKNOWN
                                fi
                        done

			echo -ne "CPU utilization for all Lpar on $ATTRIBUTE - OK |$nagiosPerfdata \n`cat $ResultOutFile`"
                else
                        echo -ne "Error: No lpar found on $ATTRIBUTE\n"
                fi
        fi
    ;;
    *)
            echo "ERROR: Unknown check type \"$checkType\". Read the help"
	    print_usage
            exitCode=3
    ;;
esac
        
################################################################################
# FINISH
################################################################################

# Print OUTPUT
echo -e "$OUTPUT\n"

# delete the tmp file
rm -rf $CmdOutFile
rm -rf $CmdOutFileSys
rm -rf $CmdOutFileLpar
rm -rf $ResultOutFile

exit $exitCode

