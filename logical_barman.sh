#!/bin/bash
# ---------------------------------------------------------------------------
# File   : $logical_barman.sh
# Ver    : 01.0
# =====================================================================================
# Modification history
#
# Version Date       Author              Comments
# ------- ---------- ------------------- ----------------------------------------------
# 01.0    09/06/2017 Georgi Kostov       Creation(catch status of Barman)
# 01.1    18/08/2017 Georgi Kostov       adding pglogical automation
# ---------------------------------------------------------------------------

STATUS="UNKNOWN"
#FUNC=$1
BKPHOST=`hostname`
MAIL_BODY=`date +"%d/%m/%Y %H:%M:%S"`"\n""---------------------------------------------------""\n"
SCRIPTSTART=`date +"%Y-%m-%d %H:%M:%S"`
BCK_LOG=/var/lib/barman/log/bkp_${DBHOST}.log
MAIL_FROM=barman@xxxxx.bg
#MAIL_TO="gkostov@xxxxx.bg"
MAIL_TO="db@xxxxx.bg"
DBHOST="$BARMAN_SERVER"
PHASE="$BARMAN_PHASE"
BKPDIR="$BARMAN_BACKUP_DIR"
ERROR="$BARMAN_ERROR"
BCURID="$BARMAN_BACKUP_ID"
strSTAT="$BARMAN_STATUS"
RETEN="+4"
BCK_LOG=/var/lib/barman/log/bkp_${DBHOST}.log
NOTIFY=false
SRVTYPE="${DBHOST#*-}"
# ----------------------
# FUnctions
# ----------------------

## ----------------------
# check PHASE of backup
## ----------------------
#fctPhaseChk()
#{
#   if [ $PHASE = "pre" ] && [$SRVTYPE=~^reportdb*.]; then
#        echo "Backup Start:" ${SCRIPTSTART}"\n""For Database:"$DBHOST","$SRVTYPE"\n">>$BCK_LOG
#        ##call func to disbale pglogical
#        fctDisableRep
#        ##call func to copy slot files
#        fctCopySlot
#   if [ $PHASE = "post" ] ; then
#        ##call func to enable pglogical
#        fctEnableRep
#        ##call func to chek status
#        fctGetStatus
#            else
#           echo "ba li go ko stana"  >>$BCK_LOG
#        fi
#    fi
#}
fctPhaseChk()
{
 case ${PHASE} in
             pre)
                    if [[ $SRVTYPE =~ ^reportdb* ]]
                        then
                        echo -e "REPORTING Database Backup Start: ${SCRIPTSTART} \n For Database:$DBHOST,$SRVTYPE \n">>$BCK_LOG
                        fctDisableRep
                        fctCopySlot
                    else echo -e "Normal Database backup start  ${SCRIPTSTART} \n For Database:$DBHOST,$SRVTYPE \n">>$BCK_LOG
                    fi
                ;;
             post)
                  if [[ $SRVTYPE =~ ^reportdb* ]]
                    then
                    fctEnableRep
                    fctGetStatus
                    fctPgRestart
                    else
                    fctGetStatus
                    fi
                ;;
        esac
}

## ----------------------
# func disbale pglogical
## ----------------------
fctDisableRep()
{
for dbs in maindb traderealdb tradefundb
do
    echo -e "Temporarily disabling Pglogical subscription $dbs">>$BCK_LOG
    psql -U barman -h $DBHOST -d repdb -c "select * from pglogical.alter_subscription_disable('$dbs',false)"
    psql_exit_status = $?
    sleep 10
        if [ $psql_exit_status != 0 ]; then
            echo "psql failed $psql_exit_status " 1>&2>>$BCK_LOG
            exit $psql_exit_status
        fi
done
}

## ----------------------
# func  enable pglogical
## ----------------------
fctEnableRep()
{
for dbs in maindb traderealdb tradefundb
do
    echo -e "Enabling Pglogical subscription $dbs">>$BCK_LOG
    psql -U barman -h $DBHOST -d repdb -c "select * from pglogical.alter_subscription_enable('$dbs',false)"
     psql_exit_status = $?
        if [ $psql_exit_status != 0 ]; then
            echo "psql failed " 1>&2>>$BCK_LOG
            exit $psql_exit_status
        fi
done
}

## ----------------------
# func  copy slot files
## ----------------------
fctCopySlot()
{
psql -U barman -d admindb  --no-align -t --field-separator ' ' --quiet -c "
    SELECT t3.dbhost as maindbs
    FROM db_rel t1
    JOIN db_cfg as t2 on  t1.rep_db = t2.sno
    JOIN db_cfg as t3 on  t1.op_db = t3.sno
    where t2.dbhost='$DBHOST' and t2.db ='repdb';
    "|while read maindbs;
        do
            echo -e "Copy slot files from $DBHOST local to barman server">>$BCK_LOG
            rsync -haze ssh postgres@$maindbs:/var/lib/postgresql/9.6/main/pg_replslot/* /var/lib/barman/$DBHOST/slots
        done
}

fctPgRestart()
{
 sleep 30
     echo -e "Restarting PostgreSQL to fix logical bug for host $DBHOST">>$BCK_LOG
        ssh -t postgres@$DBHOST "nohup /usr/lib/postgresql/9.6/bin/pg_ctl restart -D /var/lib/postgresql/9.6/main  -o '--config-file=/etc/postgresql/9.6/main/postgresql.conf' >./nohup.out 2>&1"
            echo $? >>$BCK_LOG
}
# ----------------------
#chek status
# ----------------------

fctGetStatus()
{
        case ${strSTAT} in
             EMPTY)
                    if test "${PHASE}" = "post" ; then
                    strSTAT="FAILED"
                    STATUS="FAILED"
                    fctToLog
                    else fctToLogst
                    fi
                ;;
             DONE)
                   STATUS="SUCCESS"
                   fctToLog
                    fctToPSQL
                ;;
             FAILED) STATUS="FAILED"
                    fctToLog
                    fctToMail
                    fctToPSQL
                ;;
        esac
}
# ----------------------
#fct that write statuses to log file
#log files can be find et $HOME/log/
# ----------------------
fctToLogst()
{
 echo "BACKUP START at:"$MAIL_BODY >>$BCK_LOG
 echo "Status :${strSTAT}">>$BCK_LOG
}
fctToLog()
    {
        echo -e "Backup Finish at:" ${SCRIPTSTART}"\n""For Database:"$DBHOST"\n">>$BCK_LOG
        echo -e "Backup ID is:"$BCURID "\n""Status" $STATUS >>$BCK_LOG
        echo -e "---------------------------------------------------""\n">>$BCK_LOG
    }
# ----------------------
#fct that send mail
# ----------------------
fctToMail()
    {
        MAIL_BODY="$MAIL_BODY\n\nStop at:`date +'%d/%m/%Y %H:%M:%S'` and reason is: $ERROR\n Please also check:$BCK_LOG"
        (echo "Subject: PostgreSQL Backup on ${DBHOST} has ${STATUS}";echo;echo "$MAIL_BODY") | /usr/lib/sendmail -F ${MAIL_FROM} ${MAIL_TO}
        NOTIFY=true
    }
# ----------------------
#fct that clean old wals
# ----------------------
fctCleanWal()
{
find $BKPDIR -type f -name "00000*.backup" -mtime $RETEN  -exec find -name "00000*" ! -newer {} \;|xargs  ls -la >>$BCK_LOG
find $BKPDIR -type f -name "00000*.backup" -mtime $RETEN  -exec find -name "00000*" ! -newer {} \;|xargs  rm -f
}


# ----------------------
#fct to insert rows for every backup to local PSQL database

fctToPSQL()
{
    SIZE=`du -sm $BKPDIR | awk '{print $1}'|sed -e "s/[a-zA-Z/ \-]//g"`
psql -U barman -d admindb -c "INSERT INTO public.bbackups(sno, bkphost, dbhost, bkpid, status, error, date, dir, size, notify) VALUES (DEFAULT , '{$BKPHOST}', '{$DBHOST}', '{$BCURID}', '{$strSTAT}', '{$ERROR}', current_timestamp, '{$BKPDIR}',$SIZE ,$NOTIFY);"

    psql_exit_status = $?
        if [ $psql_exit_status != 0 ]; then
        echo "psql failed while trying to run this sql script" 1>&2>>$BCK_LOG
        exit $psql_exit_status
        fi

}

fctPhaseChk

