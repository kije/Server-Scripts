#!/bin/bash

##  The MIT License (MIT)
## 
## Copyright (c) 2015 Kim D. Jeker (kije) <github@kije.ch>
## 
## Permission is hereby granted, free of charge, to any person obtaining a copy
## of this software and associated documentation files (the "Software"), to deal
## in the Software without restriction, including without limitation the rights
## to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
## copies of the Software, and to permit persons to whom the Software is
## furnished to do so, subject to the following conditions:
## 
## The above copyright notice and this permission notice shall be included in
## all copies or substantial portions of the Software.
## 
## THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
## IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
## FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
## AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
## LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
## OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
## THE SOFTWARE.

## Usage: backup.sh 
##
## This script creates full system backup to a remote ftp server. 
## It uses pipes to avoid writing redundant backup data to the local disk 
## (and hence does not require any free space left on it)
## 
##
## How to use it:
## Modify the part between "START BACKUP" and "END BACKUP" according to your needs
## Then, let the script run periodically via a cronjob.
## 
## Requirements:
## - curl
## - p7z
## - tar
## - gzip
## 
## 
## TODO:
## - Clean up output
## - remove DB backups written to disk

# Check if root?
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi


### System Setup ###
BACKUP="/backup"

## Day number -> creates file 01 ... 31 and overwrites it in the next month -> oldes backup max. 31 days old (poor man's space management) ###
BKP_NR=$(date +%d)
NOW=$(date +%Y%m%d)

### ENC
ECRYPTION_KEY="YOUR_ARCHIVE_PASSWORD_HERE"

### FTP ###
FTPD="DIRECTORY_ON_FTP_SERVER_GOES_HERE"
FTPU="FTP_SERVER_USERNAME_GOES_HERE"
FTPP="FTP_SERVER_PASSWORD_GOES_HERE"
FTPS="FTP_SERVER_ADDRESS_GOES_HERE"

### Mysql ###
MUSER="MYSQL_USER"
MPASS="MYSQL_PASSWORD"
MHOST="MYSQL_HOST"

### Binaries ###
## Todo maybe replace with fixed paths?
TAR="$(which tar)"
GZIP="$(which gzip)"
MYSQL="$(which mysql)"
MYSQLDUMP="$(which mysqldump)"
DPKG="$(which dpkg)"
IPTABLES="/sbin/iptables"
IPTABLES_SAVE="/sbin/iptables-save"
PGDUMPALL="$(which pg_dumpall)"
SU="$(which su)"
TOUCH="$(which touch)"
P7Z="$(which 7z)"
MKFIFO="$(which mkfifo)"
CURL="$(which curl)"


TAR_DIR_BUFFER=""

echo "------------------------------------------"
echo "Date: $(date)"
echo "------------------------------------------"

#################################### START BACKUP #####################################

################## DATA BACKUP ############
echo
echo "------------- File Backup ---------------"
echo

### Directory for data ###
BACKUP_DIRECTORY=$BACKUP/$BKP_NR
mkdir -p $BACKUP_DIRECTORY


### Backup files ###
echo "Backing up files using tar"
TAR_DIR_BUFFER="/etc /home /root /var /srv /opt /usr"

### Backup installed software ###
echo "Backup installed packages"
$DPKG --get-selections > $BACKUP_DIRECTORY/dpkg-selections.txt

### Backup iptables ###
echo "Backup iptables rules"
$IPTABLES -nvL > $BACKUP_DIRECTORY/iptables_overview.txt
$IPTABLES_SAVE > $BACKUP_DIRECTORY/iptables_export.txt

################## DB BACKUP ###############
echo
echo "------------- DB Backup ---------------"
echo
DB_BACKUP=$BACKUP_DIRECTORY/db

## Create db temp dir ##
echo "Create DB Backup Directory: $DB_BACKUP"
mkdir -p $DB_BACKUP

### Backup mysql ###
echo "Backup MySQL Databases"
MYSQL_DB_DIR=$DB_BACKUP/mysql

DBS="$($MYSQL -u $MUSER -h $MHOST -p$MPASS -Bse 'show databases')"
echo $DBS

for db in $DBS
do
	## Backup db ###
	echo $db
	DB_DIR=$MYSQL_DB_DIR/$db
	echo "Create DB DIR: $DB_DIR"
	mkdir -p $DB_DIR
	FILE=$DB_DIR/$db.sql
	echo "Dump DB to File: $FILE"
	$MYSQLDUMP --skip-add-locks --quote-names --skip-lock-tables --add-drop-table --allow-keywords -q -c -u $MUSER -h $MHOST -p$MPASS $db $i > $FILE
done

### Backup POSTGRES ###
echo "Backup PostgreSQL Database Cluster"
POSTGRES_DB_DIR=$DB_BACKUP/postgre
echo "Create PostgreSQL DB Dir: $POSTGRES_DB_DIR"
mkdir -p $POSTGRES_DB_DIR

POSTGRES_DUMP_FILE=$POSTGRES_DB_DIR/postgres_dump.sql
echo "Dump Cluster: $POSTGRES_DUMP_FILE"
$SU postgres -c "$PGDUMPALL" > $POSTGRES_DUMP_FILE


### archive db backups
DB_ARCHIVE=$DB_BACKUP/db-$NOW.tar
DB_ARCHIVED=$DB_BACKUP

echo "Archive $DB_ARCHIVED -> $DB_ARCHIVE"
$TAR -cf $DB_ARCHIVE $DB_ARCHIVED

# clean up
echo "Clean up $DB_BACKUP"
mv $DB_ARCHIVE $BACKUP_DIRECTORY
rm -rf $DB_ARCHIVED

# add date file to backup
echo "Create date file ($NOW)"
$TOUCH $BACKUP_DIRECTORY/$NOW

################## COMBINE BACKUPS & ENCRYPT ###############
echo
echo "------------- Compress & Encrypt ---------------"
echo
ARCHIVE_FILENAME=server-$BKP_NR.xz
ARCHIVE=$BACKUP/$ARCHIVE_FILENAME
ARCHIVED=$BACKUP_DIRECTORY

BACKUP_MAIN_PIPE=$ARCHIVE
$MKFIFO $BACKUP_MAIN_PIPE

$TAR --acls --selinux --xattrs -pc $TAR_DIR_BUFFER $BACKUP_DIRECTORY | $P7Z a -si -an -txz -m0=lzma2 -mx=9 -mfb=64 -md=32m -ms=on -mhe=on -mhc=on -p "$ECRYPTION_KEY" -so > $BACKUP_MAIN_PIPE &
#################################### END BACKUP ####################################


#################################### START TRANSFER ################################
echo
echo "------------- Upload ---------------"
echo

### ftp ###
cd $BACKUP
DUMPFILE=$ARCHIVE_FILENAME

echo "Start upload"
echo "	$DUMPFILE -> $FTPD/$DUMPFILE"
echo "on $FTPS as user $FTPU"

$CURL -T $ARCHIVE ftp://$FTPS$FTPD/$DUMPFILE --user $FTPU:$FTPP

echo
echo "Upload finished"

### clear ###
echo "Remove local backup files"
rm -rf $ARCHIVED
rm -rf $ARCHIVE

echo "Finished!"
