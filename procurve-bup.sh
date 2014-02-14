#!/bin/bash

# Copyright (c) 2013 Phillip Smith
# See LICENSE file for licensing terms.

set -e
set -u

function usage() {
  echo "$0 -n name -a -g -o output_path/" >&2
  echo >&2
  echo "-o   Path to store the downloaded configuration files" >&2
  echo "-g   Treat output_path/ as a git repo and commit configuration files" >&2
  echo "-a   Create a tarball containing all the downloaded files" >&2
}

### this function initializes a directory to be a git repository if it
### isn't already. the .gitignore file is also created.
function git_init() {
  # initialize the directory if it's not already
  if [[ ! -d '.git' ]] ; then
    git init > /dev/null
    # ignore any tarball archives
    echo '*.tar.gz' > .gitignore
    # ignore daily config
    echo '*/*_*_*-config' >> .gitignore

    git_add_and_commit 'initial commit' .gitignore
  fi

  return 0
}

### this function is for adding new/changed files to the git tree and then
### commiting those changes. it assumes the pwd is an existing git repo.
### usage: git_add_and_commit "Commit msg" file1 file2 ... fileN
function git_add_and_commit() {
  local commit_msg="$1"
  shift

  for fname in "$@" ; do
    # add all the new files
    git add -f "$fname" > /dev/null || true
  done

  # commit changes
  git commit \
    --author="procurve-bup <$USER@$HOSTNAME>" \
    --allow-empty-message \
    --message="$commit_msg" > /dev/null || true

  return 0
}

### initialize our variables
outdir=
create_archive=
do_git=

### guess our config file name
if [[ -f './procurve-bup.conf' ]] ; then
  conf_file='./procurve-bup.conf'
elif [[ -f '~/.procurve-bup.conf' ]] ; then
  conf_file='~/.procurve-bup.conf'
elif [[ -f '/etc/procurve-bup.conf' ]] ; then
  conf_file='/etc/procurve-bup.conf'
else
  # hopefully the user will tell us below; set our variable to something we
  # know does not exist to ensure error if the user doesn't tell us.
  conf_file='./procurve-bup.conf'
fi

### fetch out cmdline options
while getopts ":hagc:o:" opt; do
  case $opt in
    c)
      conf_file="$OPTARG"
      ;;
    o)
      outdir="$OPTARG"
      ;;
    a)
      create_archive=1
      ;;
    g)
      do_git=1
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
conf_file="$(readlink -f $conf_file)"

### prepare the destination
[[ ! -d "$outdir" ]] && mkdir -p "$outdir"
cd $outdir
[[ $do_git ]] && git_init

### grep the config file for all non-commented lines and pipe that
### to a 'read' to get the 3 colums of data we need
grep -P '^\s*[^#;]' "$conf_file" | while read name addr user pw ; do
  # got all the info we need?
  [[ -z "$name" ]]  && { echo "ERROR: no name specified" >&2; exit 1; }
  [[ -z "$addr" ]]  && { echo "ERROR: no address for $name specified" >&2; exit 1; }
  [[ -z "$user" ]]  && { echo "ERROR: no username for $name specified" >&2; exit 1; }
  [[ -z "$pw" ]]    && { echo "ERROR: no password for $name specified" >&2; exit 1; }

  echo "====> Backing up $name ($addr)"
  [[ ! -d "$name" ]] && mkdir "$name"
  pushd "$name" > /dev/null

  ### fetch the configs
  failed=0
  for cfg in startup-config running-config ; do
    echo "  +-> $cfg"
    # attempt the transfer using expect to input the password
    expect -c "
      set timeout 30
      spawn scp ${user}@${addr}:/cfg/${cfg} \"$tfname\"
      expect \"password: \"
      send \"$pw\r\"
      expect eof
    " > /dev/null

    # check the transfer was successful and link to the proper filenames
    if [[ -f "$tfname" ]] ; then
      chmod 440 "$tfname"
      ln -f "$tfname" "${cfg}"
      mv -f "$tfname" "${name}_${now_day}_${cfg}"
    else
      echo "WARNING: Failed to retrieve $cfg from $name" >&2
      failed=1
    fi

    # add a little sleep for slow switches that cna't keep up
    sleep 3
  done

  ### check if both files transferred successfully
  sconf='startup-config'
  rconf='running-config'
  if [[ $failed -eq 0 ]] ; then
    ### commit any changes to git if required
    [[ $do_git ]] && git_add_and_commit "$name changes retrieved from $addr" "$sconf" "$rconf"

    ### see if the running-config is different to startup-config
    if ! diff -q "$sconf" "$rconf" > /dev/null ; then
      echo "WARNING: running-config not saved:" >&2
      diff -u "$sconf" "$rconf" || true >&2
      echo '' >&2
    fi
  fi

  # return to $outdir
  popd > /dev/null
done

### create a tarball archive?
if [[ $create_archive -eq 1 ]] ; then
  archive_fname="procurve-configs-$(date +%Y%m%d).tar.gz"
  echo "Creating archive $archive_fname"
  tar --create \
    --gzip \
    --preserve-permissions \
    --file "$archive_fname" \
    */*_${now_day}_*-config
  chmod 440 "$archive_fname"
fi

exit 0
