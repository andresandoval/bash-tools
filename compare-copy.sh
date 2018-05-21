#!/bin/bash

printf "Compare file copy...\n\n"

if ( (($# ==  0)) || (($# > 2)) ); then
	printf "You need to define 1 or 2 directories (target | target source)!!\n\n"
	exit 1
fi

targetDir=$1
sourceDir=${2:-`pwd`}

if [ ! -d "$sourceDir" ] || [ ! -d "$targetDir" ]; then
    printf "Target or Source directory not exists!!\n\n"
	exit 1
fi

checkOk=0
checkFail=0
checkNotFound=0

currentCount=1
sourceFilesCount=`ls "${sourceDir}"/*.* -l | wc -l`

printf "Preparing to compare $sourceFilesCount files, this can take a while...\n\n"

for fullSourceFile in "$sourceDir"/*.*; do
    prefix="($currentCount/$sourceFilesCount) "
    simpleFileName="${fullSourceFile##*/}"
    fullTargetFile="$targetDir"/"$simpleFileName"
    if [ -f "$fullTargetFile" ]; then
        sourceMd5=`md5sum "${fullSourceFile}" | awk '{ print $1 }'`
        targetMd5=`md5sum "${fullTargetFile}" | awk '{ print $1 }'`
        if [ "$sourceMd5" == "$targetMd5" ]; then
            echo "$prefix $simpleFileName -> Target file match ($sourceMd5)"
            checkOk=$((checkOk+1))
        else
            echo "$prefix $simpleFileName -> Target file not match ($sourceMd5 != $targetMd5)"
            checkFail=$((checkFail+1))
        fi
    else
        echo "$prefix $simpleFileName -> Target file not exists"
        checkNotFound=$((checkNotFound+1))
    fi
    currentCount=$((currentCount+1))
done

printf "\n\nComparation ended!!\n\n"
echo "Ok.............................................$checkOk"
echo "Fail...........................................$checkFail"
echo "Not found......................................$checkNotFound"
echo "TOTAL..........................................$sourceFilesCount"



