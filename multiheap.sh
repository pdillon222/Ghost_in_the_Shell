#!/bin/bash

#######################################################################
#############################Heapdumps.sh #############################
#######################################################################
##                                                                   ##
##   Heapdumps.sh provides a means for triggering Java heap records  ##
##   of the main JVM process on EC2 instances.                       ##
##   Records will be added to a temporary directory in /var/temp     ##
##   and then transferred to an S3 bucket named ____                 ##
##   The program will trigger:                                       ##
##     -A heap dump                                                  ##
##     -A thread dump                                                ##
##     -(where possible) a 30 second Java Flight Recording           ##
##   Single directory entries will be created in the S3 bucket       ##
##   with a 15 day ttl per created directory                         ##
##                                                                   ##
#######################################################################
#######################################################################

#AWS environment variables:
aws="/usr/bin/aws" #determine path to command
export AWS_ACCESS_KEY_ID=''
export AWS_SECRET_ACCESS_KEY=''
export AWS_DEFAULT_REGION='us-west-2'

#array containing java processes to be targetted for heap data:
java_procs=($(jcmd | grep -v sun.tools | sed 's/\([0-9]*\) .*/\1/'))              #process ID

#create the temp directory namespace:
epoch=$(date +%s)
component=$(hostname -f | awk -F'-' '{print $1}')
version=$(dpkg -l | grep ${component:0:10} | awk -F' ' '{print $3}')
datacenter=$(hostname -f | awk -F'.' '{print $3}')
environment=$(hostname -f | awk -F'.' '{print $2}')
sphere='development' #determine whether or not a more programmatic approach is necessary on dogfood
s3_bucket="plume-${sphere}-java-heapdumps"
dir_name="${component}-${version}_${datacenter}_${environment}_${sphere}_${epoch}"

#create absolute path to house temp directory and sub-dirs containing heapdumps
dir_path='/var/tmp'                                                               #path prefix for directory creation
temp_dir="${dir_path}/${dir_name}"
mkdir ${temp_dir}

cmd_exit(){
  #if successful, echo $1
  #otherwise echo error $2; run cleanup command
  if [[ $? == 0 ]]; then
    echo "$1"
  else
    echo "$2"
    [[ $3 == "remove" ]] && rm -rf ${temp_dir}
    [[ $4 == "quit" ]] && exit 1
  fi
}

heap_dumps(){
  : 'HEAP_DUMPS
    - Function will iterate through java process numbers in `java_procs` array
    - A sub-directory will be created within the temp directory path
      - sub-directory name will be that of the target java process followed by PID
    - Heap dump files will be added to sub-directory
    - Final result: temp_dir/heap_dir/[thread_dump, heap_dump, jfr]
  HEAP_DUMPS'

  java_proc="$1"
  #command aliases pertaining to targetted Java process owner:
  temp_owner=$(ps -u -p ${java_proc} --no-headers | awk '{print $1}' | sed 's/+//') #abbreviated owner name
  proc_own=$(cat /etc/passwd | grep ${temp_owner} | awk -F':' '{print $1}')         #full process owner name
  proc_id=$(cat /etc/passwd | grep ${proc_own} | awk -F':' '{print $3}')            #process owner id number
  proc_group_id=$(cat /etc/passwd | grep ${proc_own} | awk -F':' '{print $4}')      #group id of process

  #temporarily change ownership of temp directory for heap dumps
  chown ${proc_own}:${proc_group_id} ${temp_dir}
  #sub-directory being given naming convention: "process name"_"process id"
  heap_dir="${temp_dir}/${proc_own}_${proc_id}"
  mkdir ${heap_dir}
  chown ${proc_own}:${proc_group_id} ${heap_dir}

  #creation of stdout/stderr strings for output:
  jvm_unlock_out="JVM commercial features succesfully unlocked"
  jvm_unlock_err="JCMD tools not available: JFR recording will be skipped"
  heap_dump_out="Heap dump file:${heap_dir}/heapdump created succesfully"
  heap_dump_err="Heap dump failed. Exiting"
  thread_dump_out="Thread dump file:${heap_dir}/threaddump successfully created"
  thread_dump_err="Thread dump failed. Exiting"
  jfr_dump_out="Java Flight Recording written to ${heap_dir}/heaprecord.jfr"
  jfr_dump_err="JFR tools not available per process ${java_proc}"
  aws_transfer_out="Transfer successful"
  aws_transfer_err="JFR tools not available per process ${java_proc}"

  #unlock Vm commercial features:
  sudo -s -u ${proc_own} jcmd ${java_proc} VM.unlock_commercial_features
  cmd_exit "$jvm_unlock_out" "$jvm_unlock_err"

  #heap dump to temp_dir:
  sudo -s -u ${proc_own} jmap -dump:file="${heap_dir}/heapdump" ${java_proc}
  cmd_exit "$heap_dump_out" "$thread_dump_err" remove quit

  #thread-dump to temp_dir:
  sudo -s -u ${proc_own} jcmd ${java_proc} Thread.print >> "${heap_dir}/threaddump"
  cmd_exit "$thread_dump_out" "$thread_dump_err" remove quit

  #create a JFR (to /var/tmp/test.jfr [30 second duration], not all instances appear to have this ability):
  sudo -s -u ${proc_own} jcmd ${java_proc} JFR.start name=TestRecording settings=profile delay=2s \
duration=2s filename="${heap_dir}/heaprecord.jfr" > /dev/null 2>&1
  if [[ $? == 0 ]];then
    echo ${jfr_dump_out}
    #the shell does not wait for the JFR recording to finish
    #sleeping to ensure completion of recording
    sleep 2
    #a statement appended to end of recording, as a simple watermark of completion:
    echo "\n#############END#############" >> ${heap_dir}/heaprecord.jfr
  else
    echo "$jfr_dump_err"
    #some procs do not have JFR capability, will not exit in case of error
  fi
}

for i in ${java_procs[*]}; do
  heap_dumps $i
done

##dump the folder to an S3 bucket, then remove the temp directory
${aws} s3 sync ${temp_dir} s3://${s3_bucket}/${dir_name}
cmd_exit "$aws_transfer_out" "$aws_transfer_err" remove quit

#remove the temporary directory:
[[ ! "$temp_dir" == '/' ]] && rm -rf "$temp_dir"
