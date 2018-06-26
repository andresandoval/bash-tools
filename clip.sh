#!/bin/bash

if [[ $# -eq 0 ]];  then
	echo "No arguments.."
	exit 0
fi

fileName=$1
fullFilePath=`realpath "$fileName"`

echo -n "$fullFilePath" | xclip -selection clipboard
echo "Copied file path '$fullFilePath' to clipboard"
