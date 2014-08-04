#!/bin/bash

# Copyright (c) 2013 Phillip Smith
# See LICENSE file for licensing terms.

set -e
set -u

### static variables (how ironic)
readonly PROGNAME='procurve-bup'
readonly LOG_FACILITY='user'

### global runtime variables
quiet=

function usage() {
  echo "$0 -n name -a -q -o output_path/" >&2
  echo >&2
  echo "-o   Path to store the downloaded configuration files" >&2
  echo "-a   Create a tarball containing all the downloaded files" >&2
  echo "-q   Be quiet" >&2
}

function log2syslog() {
  local _priority="$1"
  local _quiet="$2"
  local _msg="$3"

  if [[ "$_quiet" == 1 ]] ; then
    # just log to syslog
    logger -it $PROGNAME -p ${LOG_FACILITY}.${_priority} -- $_msg
  else
    # log the message to syslog and to stderr
    logger -sit $PROGNAME -p ${LOG_FACILITY}.${_priority} -- $_msg
  fi
}
function log_notice() {
  log2syslog "notice" "$quiet" "$1"
}
function log_warn() {
  log2syslog "warn" 0 "$1"
}
function log_err() {
  log2syslog "err" 0 "$1"
}

function guess_config_fname() {
  # try to guess our config file name
  if [[ -e './procurve-bup.conf' ]] ; then
    echo './procurve-bup.conf'
    return 0
  elif [[ -e ~/.procurve-bup.conf ]] ; then
    echo ~/.procurve-bup.conf
    return 0
  elif [[ -e '/etc/procurve-bup.conf' ]] ; then
    echo '/etc/procurve-bup.conf'
    return 0
  fi
  return 1
}

function main() {
  ### runtime variables
  local _outdir=
  local _create_archive=
  local _now_day=$(date +%a)     # eg, Sun, Mon, Tue
  local _tfname=".switchbup-$$"  # temp filename for transfer to avoid blatting exiting backup with failed backup

  local _config_fname=$(guess_config_fname)

  ### fetch out cmdline options
  while getopts ":haqc:o:" opt; do
    case $opt in
      c)
        _config_fname="$OPTARG"
        ;;
      o)
        _outdir="$OPTARG"
        ;;
      a)
        _create_archive=1
        ;;
      q)
        quiet=1
        ;;
      h)
        usage
        exit 0
        ;;
      \?)
        echo "ERROR: Invalid option: -$OPTARG" >&2
        usage
        exit 1
        ;;
      :)
        echo "ERROR: Option -$OPTARG requires an argument." >&2
        exit 1
        ;;
      esac
  done

  ### verify user supplied data
  [[ -z "$_outdir" ]]      && { echo "ERROR: no output path specified" >&2; exit 1; }
  [[ -z "$_config_fname" ]]   && { echo "ERROR: no config file found" >&2; exit 1; }
  [[ ! -f "$_config_fname" ]] && { echo "ERROR: config file not found" >&2; exit 1; }
  [[ ! -r "$_config_fname" ]] && { echo "ERROR: config file permission denied" >&2; exit 1; }

  # we change our working directory below so we need to know
  # the absolute path to the configuration file (the user might
  # have given us a relative path)
  _config_fname="$(readlink -f $_config_fname)"

  ### prepare the destination
  [[ ! -d "$_outdir" ]] && mkdir -p "$_outdir"
  cd "$_outdir"

  ### grep the config file for all non-commented lines and pipe that
  ### to a 'read' to get the 3 colums of data we need
  grep -P '^\s*[^#;]' "$_config_fname" | while read name addr user pw ; do
    # got all the info we need?
    [[ -z "$name" ]]  && { log_err "ERROR: no name specified" >&2; exit 1; }
    [[ -z "$addr" ]]  && { log_err "ERROR: no address for $name specified" >&2; exit 1; }
    [[ -z "$user" ]]  && { log_err "ERROR: no username for $name specified" >&2; exit 1; }
    [[ -z "$pw" ]]    && { log_err "ERROR: no password for $name specified" >&2; exit 1; }

    log_notice "Backing up $name ($addr)"
    [[ ! -d "$name" ]] && mkdir "$name"
    pushd "$name" > /dev/null

    ### fetch the configs
    failed=0
    for cfg in startup-config running-config ; do
      log_notice "Fetching '$cfg' via SSH"
      # attempt the transfer using expect to input the password
      expect -c "
        set timeout 30
        spawn scp ${user}@${addr}:/cfg/${cfg} \"$_tfname\"
        expect \"password: \"
        send \"$pw\r\"
        expect eof
      " > /dev/null

      # check the transfer was successful and link to the proper filenames
      if [[ -f "$_tfname" ]] ; then
        # transfer was successful! make the file read-only and move
        # it into place from our temp file to the proper filename
        chmod 440 "$_tfname"
        ln -f "$_tfname" "${cfg}"
        mv -f "$_tfname" "${name}_${_now_day}_${cfg}"
      else
        log_warn "Failed to retrieve $cfg from $name!" >&2
        failed=1
      fi

      # add a little sleep for slow switches that cna't keep up
      sleep 3
    done

    ### check if both files transferred successfully
    if [[ $failed -eq 0 ]] ; then
      ### see if the running-config is different to startup-config
      if ! diff -q startup-config running-config > /dev/null ; then
        log_warn "running-config and startup-config differ!" >&2
      fi
    fi

    # return to $outdir
    popd > /dev/null
  done

  ### create a tarball archive?
  if [[ -n "$_create_archive" ]] ; then
    local _archive_fname="procurve-configs-$(date +%Y%m%d).tar.gz"
    log_notice "Creating tarball archive: $_archive_fname"
    tar --create \
      --gzip \
      --preserve-permissions \
      --file "$_archive_fname" \
      */*_${now_day}_*-config
    chmod 440 "$_archive_fname"
  fi

  exit 0
}

main "$@"
