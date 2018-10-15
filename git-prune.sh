#!/bin/bash

printf "Git pruning helper tool...\n\n"

imOnGitDir=$(git rev-parse --is-inside-work-tree)

if [ ! "$imOnGitDir" = "true" ]; then
	printf "Current directory is not under a GIT repository!!\n\n"
	exit 1
fi

echo "(1/2) Fetching repository..."
git fetch --prune
echo "(2/2) Deleting all stale remote-tracking branches..."
git remote prune origin

orphanBranches=$(git branch -vv | grep -v '^*' | grep 'origin/.*: gone]\|origin/.*: desaparecido]')

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
printf "\n\nRepository pruned successfully!!\n\n"



