#!/bin/bash
# shellcheck disable=SC2155

# default values
# shellcheck disable=SC2076
if [ -z "$CALL_HOST_STATUS" ]; then
	export CALL_HOST_STATUS=enable
elif [[ ! " enable disable " =~ " $CALL_HOST_STATUS " ]]; then
	echo "Warning: unsupported value $CALL_HOST_STATUS for CALL_HOST_STATUS; disabling"
	export CALL_HOST_STATUS=disable
fi
if [ -z "$CALL_HOST_DIR" ]; then
	if [[ "$(uname -a)" == *cms*.fnal.gov* ]]; then
		export CALL_HOST_DIR=~/nobackup/pipes
	elif [[ "$(uname -a)" == *.uscms.org* ]]; then
		export CALL_HOST_DIR=/scratch/$(whoami)/pipes
	else
		echo "Warning: no default CALL_HOST_DIR for $(uname -a), please set your own manually. disabling"
		export CALL_HOST_STATUS=disable
	fi
fi
export CALL_HOST_DIR=$(readlink -f "$CALL_HOST_DIR")
mkdir -p "$CALL_HOST_DIR"
# ensure the pipe dir is bound
export APPTAINER_BIND=${APPTAINER_BIND}${APPTAINER_BIND:+,}${CALL_HOST_DIR}

# concept based on https://stackoverflow.com/questions/32163955/how-to-run-shell-script-on-host-from-docker-container

# execute command sent to host pipe; send output to container pipe; store exit code
listenhost(){
	# stop when host pipe is removed
	while [ -e "$1" ]; do
		# "|| true" is necessary to stop "Interrupted system call"
		# must be *inside* eval to ensure EOF once command finishes
		# now replaced with assignment of exit code to local variable (which also returns true)
		tmpexit=0
		eval "$(cat "$1") || tmpexit="'$?' >& "$2"
		echo "$tmpexit" > "$3"
	done
}
export -f listenhost

# creates randomly named pipe and prints the name
makepipe(){
	PREFIX="$1"
	PIPETMP=${CALL_HOST_DIR}/${PREFIX}_$(uuidgen)
	mkfifo "$PIPETMP"
	echo "$PIPETMP"
}
export -f makepipe

# to be run on host before launching each apptainer session
startpipe(){
	HOSTPIPE=$(makepipe HOST)
	CONTPIPE=$(makepipe CONT)
	EXITPIPE=$(makepipe EXIT)
	# export pipes to apptainer
	echo "export APPTAINERENV_HOSTPIPE=$HOSTPIPE; export APPTAINERENV_CONTPIPE=$CONTPIPE; export APPTAINERENV_EXITPIPE=$EXITPIPE"
}
export -f startpipe

# sends function to host, then listens for output, and provides exit code from function
call_host(){
	if [ "${FUNCNAME[0]}" = "call_host" ]; then
		FUNCTMP=
	else
		FUNCTMP="${FUNCNAME[0]}"
	fi
	echo "cd $PWD; $FUNCTMP $*" > "$HOSTPIPE"
	cat < "$CONTPIPE"
	return "$(cat < "$EXITPIPE")"
}
export -f call_host

# from https://stackoverflow.com/questions/1203583/how-do-i-rename-a-bash-function
copy_function() {
	test -n "$(declare -f "$1")" || return
	eval "${_/$1/$2}"
	eval "export -f $2"
}
export -f copy_function

if [ -z "$APPTAINER_ORIG" ]; then
	export APPTAINER_ORIG=$(which apptainer)
fi
# always set this (in case of nested containers)
export APPTAINERENV_APPTAINER_ORIG=$APPTAINER_ORIG

apptainer(){
	if [ "$CALL_HOST_STATUS" = "disable" ]; then
		(
		# shellcheck disable=SC2030
		export APPTAINERENV_CALL_HOST_STATUS=disable
		$APPTAINER_ORIG "$@"
		)
	else
		# in subshell to contain exports
		(
		# shellcheck disable=SC2031
		export APPTAINERENV_CALL_HOST_STATUS=enable
		# only start pipes on host
		# i.e. don't create more pipes/listeners for nested containers
		if [ -z "$APPTAINER_CONTAINER" ]; then
			eval "$(startpipe)"
			listenhost "$APPTAINERENV_HOSTPIPE" "$APPTAINERENV_CONTPIPE" "$APPTAINERENV_EXITPIPE" &
			LISTENER=$!
		fi
		# actually run apptainer
		$APPTAINER_ORIG "$@"
		# avoid dangling cat process after exiting container
		# (again, only on host)
		if [ -z "$APPTAINER_CONTAINER" ]; then
			pkill -P "$LISTENER"
			rm -f "$APPTAINERENV_HOSTPIPE" "$APPTAINERENV_CONTPIPE" "$APPTAINERENV_EXITPIPE"
		fi
		)
	fi
}
export -f apptainer

# on host: get list of condor executables
if [ -z "$APPTAINER_CONTAINER" ]; then
	export APPTAINERENV_HOSTFNS=$(compgen -c | grep '^condor_\|^eos')
	if [ -n "$CALL_HOST_USERFNS" ]; then
		export APPTAINERENV_HOSTFNS="$APPTAINERENV_HOSTFNS $CALL_HOST_USERFNS"
	fi
# in container: replace with call_host versions
elif [ "$CALL_HOST_STATUS" = "enable" ]; then
	# shellcheck disable=SC2153
	for HOSTFN in $HOSTFNS; do
		copy_function call_host "$HOSTFN"
	done
fi
