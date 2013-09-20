#!/usr/bin/env bash

set -e
set -u

function usage() {
  echo "$0 -n name -a address -p password_file -o output_path/" >&2
  echo >&2
  echo "password_file is a single line file containing the password to" >&2
  echo "use to authenticate with the switch." >&2
}

### initialize our variables
conf_file='./procurve-bup.conf'
outdir=

### fetch out cmdline options
while getopts ":hc:o:" opt; do
  case $opt in
    c)
      conf_file="$OPTARG"
      ;;
    o)
      outdir="$OPTARG"
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
[[ -z "$outdir" ]]      && { echo "ERROR: no output path specified" >&2; exit 1; }
[[ ! -f "$conf_file" ]] && { echo "ERROR: config file not found" >&2; exit 1; }
[[ ! -r "$conf_file" ]] && { echo "ERROR: config file permission denied" >&2; exit 1; }

### runtime variables
now_day=$(date +%a)     # eg, Sun, Mon, Tue
now_month=$(date +%b)   # eg, Jan, Feb, Mar
tfname=".switchbup-$$"  # temp filename for transfer to avoid blatting exiting backup with failed backup
conf_file="$(realpath $conf_file)"

### prepare the destination
[[ ! -d "$outdir" ]] && mkdir -p $outdir
cd $outdir

### grep the config file for all non-commented lines and pipe that
### to a 'read' to get the 3 colums of data we need
grep -P '^\s*[^#;]' $conf_file | while read name addr pw ; do
  # got all the info we need?
  [[ -z "$name" ]]  && { echo "ERROR: no name specified" >&2; exit 1; }
  [[ -z "$addr" ]]  && { echo "ERROR: no address for $name specified" >&2; exit 1; }
  [[ -z "$pw" ]]    && { echo "ERROR: no password for $name specified" >&2; exit 1; }

  echo "====> Backing up $name ($addr)"

  ### fetch the configs
  for cfg in startup-config running-config ; do
    echo "  +-> $cfg"
    # attempt the transfer using expect to input the password
    expect -c "
      set timeout 30
      spawn scp admin@$addr:/cfg/${cfg} \"$tfname\"
      expect \"password: \"
      send \"$pw\r\"
      expect eof
    " > /dev/null

    # check the transfer was successful and link to the proper filenames
    if [[ -f "$tfname" ]] ; then
      chmod 440 "$tfname"
      mv -f "$tfname" "${name}_${now_day}_${cfg}"
    else
      echo "WARNING: Failed to retrieve $cfg from $name" >&2
    fi
  done

  ### see if the running-config is different to startup-config
  sconf="${name}_${now_day}_startup-config"
  rconf="${name}_${now_day}_running-config"
  if [[ -f "$sconf" ]] && [[ -f "$rconf" ]] ; then
    if ! diff -q "$sconf" "$rconf" > /dev/null ; then
      echo "WARNING: running-config not saved:"
      diff -u "$sconf" "$rconf"
      echo
    fi
  fi
done

exit 0
