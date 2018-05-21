#!/bin/bash

printf "Git pruning helper tool...\n\n"

currentDir=$(pwd)
gitDir="$currentDir/.git"

if [ ! -d "$gitDir" ]; then
	printf "Current directory is not under GIT management!!\n\n"
	exit 1
fi

echo "(1/2) Fetching repository..."
git --git-dir $gitDir fetch --prune
echo "(2/2) Deleting all stale remote-tracking branches..."
git --git-dir $gitDir remote prune origin

orphanBranches=$(git --git-dir $gitDir branch -vv | grep -v '^*' | grep 'origin/.*: gone]\|origin/.*: desaparecido]')

if [ -z "$orphanBranches" ]; then
	printf "\nThere is no branches for pruning!!\n\n"
	exit 1
fi

echo "Following branches are going to be pruned:"
echo "$orphanBranches"

while true; do
    read -p "Do you want to continue? (y/n)" answer

    case $answer in
        [yYsS]* )
            break
        ;;
        [nN]* )
            printf "\n\nCanceled pruning.\n\n"
	        exit 1
        ;;
        * ) echo "Answer y/n"
        ;;
    esac
done

printf "\n\nPruning repository...\n"
echo "$orphanBranches" | awk '{print $1}' | xargs git branch -D
printf "\n\nRepository pruned succesfully!!\n\n"



