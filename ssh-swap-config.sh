#!/bin/bash

printf "SSH Config swapping tool...\n\n"

if [ -z "$1" ]; then
	echo "Missing schema"
	exit 22
fi

schema="${1,,}"
configFile=~/.ssh/config
schemaFile=$configFile.$schema
backupFile=$configFile.latest

echo "Moving to \"$schema\" schema..."

if ! [ -f "$schemaFile" ]; then
    echo "   \"$schemaFile\" file not exists"
	exit 2
fi

if [ -f "$configFile" ]; then
    echo "   saving current schema as backup..."
	mv -f "$configFile" "$backupFile"
fi

echo "   setting new schema..."
cp "$schemaFile" "$configFile"

echo "   done"