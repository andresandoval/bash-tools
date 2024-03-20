#!/bin/bash

swap_schema() {
	printf "Swapping ssh config...\n"
	schema_name="${1,,}"
	config_dir=~/.ssh
	config_file=$config_dir/config
	schema_file=$config_file.$schema_name
	backup_file=$config_dir/config.last.bk

	echo "Moving to \"$schema_name\" schema..."

	if ! [ -f "$schema_file" ]; then
		echo "   \"$schema_file\" file not exists"
		exit 22
	fi

	if [ -f "$config_file" ]; then
		echo "   saving current schema as backup..."
		mv -f "$config_file" "$backup_file"
	fi

	echo "   setting new schema..."
	cp "$schema_file" "$config_file"

	echo "   done"
}

check_schema() {
	config_dir=~/.ssh
	config_file=$config_dir/config
	pattern="config.*"
	found=0
	for filename in "$config_dir"/$pattern; do
		# Exclude "config.last.bk"
		if [[ $filename == "$config_dir/config.last.bk" ]]; then
			continue
		fi

		# Check if the file exists and is a regular file
		if [[ -f "$filename" ]]; then
			# Perform the comparison using cmp
			if cmp -s "$config_file" "$filename"; then
				schema_name=${filename#"$config_dir/config."}
				echo -e "Current schema is: \033[1m$schema_name\033[0m"
				found=1
			fi
		else
			echo "File $filename does not exist or is not a regular file"
			exit 22
		fi
	done
	if [[ $found -eq 0 ]]; then
		echo "Current configuration does not match any existing schema."
	fi
}

show_help() {
	echo -e "	\033[1mNAME:\033[0m

		ssh-config-tool - Tool for managing ssh config

	\033[1mSYNOPSIS:\033[0m

		ssh-config-tool --swap SCHEMA_NAME
		ssh-config-tool --check
		ssh-config-tool --help
	
	\033[1mDESCRIPTION:\033[0m

		Tool for managing ssh config.
		
		Options:

		\033[1m--swap SCHEMA_NAME\033[0m: Swap the current schema based on the SCHEMA_NAME
		\033[1m--check\033[0m: Shows the current schema
		\033[1m--help\033[0m: Shows this help
	"
}


# Check if the first argument starts with "--"
if [[ $1 == --* ]]; then
	# Handling arguments
	case "$1" in
		--swap)
			# Check if exists a second argument

			if [ -z "$2" ]; then
				echo "Missing SCHEMA_NAME, run ssh-config-tool --help for help "
				exit 22
			fi

			swap_schema "$2"
			;;
		--check)
			check_schema
			;;
		--help)
			show_help
			;;
		*)
			echo "unknown option \"$1\", run ssh-config-tool --help for help "
			exit 22 
	esac
else
	echo "Invalid arguments, run ssh-config-tool --help for help "
	exit 22
fi





