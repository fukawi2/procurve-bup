#!/bin/bash

# Copyright (c) 2013 Phillip Smith
# See LICENSE file for licensing terms.

set -e
set -u

### static variables (how ironic)
readonly PROGNAME='procurve-bup'
readonly LOG_FACILITY='user'

### global runtime variables
declare quiet=

function usage() {
  echo "$0 -c /path/file.conf -a -q -o output_path/" >&2
  echo >&2
  echo "-c   Path to configuration file" >&2
  echo "-o   Path to store the downloaded configuration files" >&2
  echo "-a   Create a tarball containing all the downloaded files" >&2
  echo "-q   Be quiet" >&2
}

function log2syslog() {
  local _priority="$1"
  local _quiet="$2"
  local _msg="$3"
  local _logger_args=

  if [[ -n "$_quiet" ]] ; then
    # just log to syslog
    _logger_args='-it'
  else
    # log the message to syslog and to stderr
    _logger_args='-sit'
  fi
  logger $_logger_args $PROGNAME -p ${LOG_FACILITY}.${_priority} -- $_msg
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

function scp_using_password() {
  local ssh_uri="$1"
  local password="$2"
  local remote_file="$3"
  local local_file="$4"

  local _ssh_opts='-q -o PubkeyAuthentication=no -o PasswordAuthentication=yes'
  local _tfile="$(mktemp)"
  chmod 600 "$_tfile"
  echo "$password" > "$_tfile"

  failed=0
  sshpass -f $_tfile \
    scp $_ssh_opts \
    ${ssh_uri}:${remote_file} \
    "$local_file" || failed=1
  rm -f "$_tfile"
  return $failed
}

function scp_using_pubkey() {
  local ssh_uri="$1"
  local pubkey_file="$2"
  local remote_file="$3"
  local local_file="$4"

  local _ssh_opts='-q -o PubkeyAuthentication=yes -o PasswordAuthentication=no'

  failed=0
  scp $_ssh_opts \
    -i "$pubkey_file" \
    ${ssh_uri}:${remote_file} \
    "$local_file" || failed=1
  return $failed
}

function main() {
  ### runtime variables
  local _outdir=
  local _create_archive=
  local _now_day=$(date +%a)     # eg, Sun, Mon, Tue
  local _tfname=".switchbup-$$"  # temp filename for transfer to avoid blatting exiting backup with failed backup

  ### check for external dependencies
  for cmd in sshpass readlink scp rm chmod logger mkdir grep ln mv diff tar ; do
    if [[ -z "$(command -v $cmd)" ]] ; then
      echo "ERROR: Missing external command '$cmd'" >&2
      exit 2
    fi
  done

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
  grep -P '^\s*[^#;]' "$_config_fname" | while read name addr user method value ; do
    # got all the info we need?
    [[ -z "$name" ]]  && { log_err "ERROR: no name specified"; exit 1; }
    [[ -z "$addr" ]]  && { log_err "ERROR: no address for $name specified"; exit 1; }
    [[ -z "$user" ]]  && { log_err "ERROR: no username for $name specified"; exit 1; }
    [[ -z "$method" ]]&& { log_err "ERROR: no method for $name specified"; exit 1; }
    case "$method" in
      'password')
        pw="$value"
        pubkey=''
        [[ -z "$pw" ]] && { log_err "ERROR: no password for $name specified"; exit 1; }
        ;;
      'pubkey')
        pw=''
        pubkey="$value"
        [[ -z "$pubkey" ]] && { log_err "ERROR: no public key for $name specified"; exit 1; }
        ;;
      *)
        log_err "ERROR: unknown method for $name: $method"
        exit 1;
        ;;
    esac

    log_notice "Backing up $name ($addr)"
    [[ ! -d "$name" ]] && mkdir "$name"
    pushd "$name" > /dev/null

    ### fetch the configs
    failed=0
    for cfg in startup-config running-config ; do
      case "$method" in
        'password')
          log_notice "Fetching '$cfg' via SSH using password auth"
          scp_using_password "${user}@${addr}" "$pw" "/cfg/${cfg}" "$_tfname" || continue
          ;;
        'pubkey')
          log_notice "Fetching '$cfg' via SSH using public key auth"
          scp_using_pubkey "${user}@${addr}" "$pubkey" "/cfg/${cfg}" "$_tfname" || continue
          ;;
      esac

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
      sleep 5
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
