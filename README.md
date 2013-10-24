procurve-bup
============

Backup script to automatically backup configurations from multiple HP Procurve
Switches

Additionally, the script will compare the `running-config` against the
`startup-config` and emit a warning if they are different (ie, the running
configuration has not been saved).

## Usage

Once you have a configuration file (see below):

    procurve-bup -o /path/to/save/backups

If you have you config file in a non-standard location, you can use the `-c`
flag to tell the script where to find it's configuration file. Standard config
locations are (in order they are checked):

* ./procurve-bup.conf
* ~/.procurve-bup.conf
* /etc/procurve-bup.conf

Add the `-a` flag to have a tarball archive of all the retrieved configuration
files created.

Additionally, using the `-g` flag will cause the output path to be treated as
a git repository and changes to config files will be automatically committed to
the tree. If the directory is not already a git repository, it will be
initialized as one (using `git init`) automatically.

## Configuration

### Switch Configuration

SSH filetransfer must be enabled on the switches you want to backup. To
enable this feature, login to the switch (via telnet or serial) and issue the
following commands after entering config mode:

    crypto key generate ssh
    ip ssh
    ip ssh filetransfer

Optionally, you can then disable the telnet server and perform administration
tasks via SSH which is encrypted:

    no telnet-server

### Configuration File

A simple configuration file listing the details of the switches to be backed
up powers the script.

The configuration file is very simple; 1 line per switch with 4 columns per
line (whitespace delimited). Comments are supported (see below).

### Format

* Column 1: A 'friendly' name for the switch (no spaces)
* Column 2: DNS host or IP Address of the switch
* Column 3: Username to login to the switch with
* Column 4: Password for the user in column 3

### Example

This example will backup 3 switches called `main-switch`, `floor1-switch` and
`floor2-switch`. An SSH connection will be made to the corresponding IP Address
and authentication will be made as user `manager` for the the switch named
`main-switch` and user `admin` for the other 2 switches. The respective
password in the forth column will be used for each connection:

    main-switch     192.168.1.10  manager my_pa55w0rd
    floor1-switch   192.168.1.11  admin   secret_pa55w0rd
    floor2-switch   192.168.1.12  admin   d0nt_tellany1

The resulting tree in the backup path will appear as below, assuming the script
was run on Friday 20th September 2013, and the `-a` flag was used:

    ./
    +-- procurve-configs-20130920.tar.gz
    +-- floor1-switch
    |   +-- floor1-switch_Fri_running-config
    |   +-- floor1-switch_Fri_startup-config
    +-- floor2-switch
    |   +-- floor2-switch_Fri_running-config
    |   +-- floor2-switch_Fri_startup-config
    +-- main-switch
    |   +-- main-switch_Fri_running-config
    |   +-- main-switch_Fri_startup-config

### Comments

* Comments are supported and marked by a hash ('#') character.
* Comments must start at the beginning of a line; comments can not start in
the middle of a line.

Good:

    main-switch     192.168.1.10  my_pa55w0rd
    # floor1 is offline at the moment, don't try to backup
    #floor1-switch   192.168.1.11  secret_pa55w0rd
    floor2-switch   192.168.1.12  d0nt_tellany1

Bad:

    main-switch     192.168.1.10  my_pa55w0rd   # this is the main switch
    floor1-switch   192.168.1.11  secret_pa55w0rd
    floor2-switch   192.168.1.12  d0nt_tellany1

## Security

1. If a connection can not be made to the switch, the password will be
displayed in the scripts' output. Be careful where this output is emailed to.
2. Passwords are stored in plain text (by necessity) in the configuration file.
Ensure proper permissions (600) are on this file.

## Supported Switches

This script has been tested as working with the following switch models:

* HP Procurve 2510-24 (`J9019B`)
* HP Procurve 2510-24G (`J9279A`)
* HP Procurve 2510-48 (`J9020A)`
* HP Procurve 2510-48G (`J9280A`)
* HP Procurve 2520-8-PoE (`J9137A`)
* HP Procurve 2620-24-PoE+ (`J9625A`)
* HP Procurve 2920-24G (`J9726A`)
