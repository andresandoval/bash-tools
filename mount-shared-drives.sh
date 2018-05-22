#!/bin/bash
printf "Mounting network drives...\n\n"
baseDir=~/Mount
if [ ! -d "$baseDir" ]; then
	mkdir $baseDir;
fi

#global
whoami=$(whoami)
uid=$(id -u $whoami)
gid=$(id -g $whoami)


#mount01: public@192.168.0.60/public
hostname01=192.168.0.60
resource01=public
username01=public
password01=public
origin01="//$hostname01/$resource01"
mount_point01="$baseDir/$hostname01-$resource01"
if [ ! -d "$mount_point01" ]; then
	mkdir -p $mount_point01;
fi
sudo mount.cifs $origin01 $mount_point01 -o username=$username01,password=$password01,uid=$uid,gid=$gid
caja $mount_point01 &
printf "\n\nThat's all...\n\n"
