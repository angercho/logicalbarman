#!/bin/bash
# ---------------------------------------------------------------------------
# File   : $logical_barman.sh
# Ver    : 01.2
# =====================================================================================
# Modification history
#
# Version Date       Author              Comments
# ------- ---------- ------------------- ----------------------------------------------
# 01.0    09/06/2017 Anger Kostov       Creation(catch status of Barman)
# 01.1    18/08/2017 Anger Kostov       adding pglogical automation
# 01.2    04/04/2018 Anger Kostov       add check for logical status and fix it if needed
# ---------------------------------------------------------------------------

STATUS="UNKNOWN"
#FUNC=$1
BKPHOST=`hostname`
MAIL_BODY=`date +"%d/%m/%Y %H:%M:%S"`"\n""---------------------------------------------------""\n"
SCRIPTNAME="logical_barman.sh"
SCRIPTSTART=`date +"%Y-%m-%d %H:%M:%S"`
BCK_LOG=/var/lib/barman/log/bkp_${DBHOST}.log
MAIL_FROM=barman@barmanserver.bg
MAIL_TO="db@your_mail.bg"
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
ENVTYPE="${DBHOST%-*}"
#database name of your logical replication
$REPDB=repdb
# ----------------------
# FUnctions
# ----------------------

## ----------------------
# check PHASE of backup change SRVTYPE to match you logical replication host
## ----------------------
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
#                    fctPgRestart
                    fctChLogical
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
psql -U barman -h $DBHOST -d $REPDB  -t -q -AF ' ' -c '\timing off' -c "SELECT sub_name
FROM pglogical.subscription;
;"|while read dbs; 
do 
    echo -e "Temporarily disabling Pglogical subscription $dbs">>$BCK_LOG
    psql -U barman -h $DBHOST -d $REPDB -c "select * from pglogical.alter_subscription_disable('$dbs',false)"
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
 psql -U barman -h $DBHOST -d $REPDB  -t -q -AF ' ' -c '\timing off' -c "SELECT sub_name
FROM pglogical.subscription;
;"|while read dbs; 
do
    echo -e "Enabling Pglogical subscription $dbs">>$BCK_LOG
    psql -U barman -h $DBHOST -d $REPDB -c "select * from pglogical.alter_subscription_enable('$dbs',false)"
     psql_exit_status = $?
        if [ $psql_exit_status != 0 ]; then
            echo "psql failed " 1>&2>>$BCK_LOG
            exit $psql_exit_status
        fi
done
}


## ----------------------
# func  copy slot files from primary db hosts
## ----------------------
fctCopySlot()
{
psql -U barman -h $DBHOST -d $REPDB -t -q -AF ' ' -c '\timing off' -c "
        select distinct (select v
                      from (select split_part(x,'=',1) k, split_part(x,'=',2) v
                      from (select unnest((select string_to_array(ifc.if_dsn, ' '))) x) a
                            ) c where k = 'host')
    from pglogical.node_interface ifc
    join pglogical.subscription sb
    on sb.sub_origin_if= ifc.if_id;
    "|while read maindbs;
        do
            echo -e "Copy slot files from $DBHOST local to barman server">>$BCK_LOG
            rsync -haze ssh postgres@$maindbs:/var/lib/postgresql/10/main/pg_replslot/* /var/lib/barman/$DBHOST/slots/$BCURID
        done
}
## ----------------------
# func that check logical status
## ----------------------
fctChLogical()
{
psql -U barman -h $DBHOST -d $REPDB -t -q -AF ' ' -c '\timing off' -c "select status from pglogical.show_subscription_status();
"|while read status; 
    do 
        if [[ "$status" = "replicating" ]]
            then 
                echo -e "check logical slot: ok">>$BCK_LOG
            else 
                echo -e "slot not ok ......restarting">>$BCK_LOG
                fctPgRestart
                sleep 10
                break
        fi
    done
}
## ----------------------
# func  restart logical cluster
## ----------------------

fctPgRestart()
{
 sleep 5
     echo -e "Restarting PostgreSQL to fix logical bug for host $DBHOST">>$BCK_LOG
        ssh -t postgres@$DBHOST "nohup /usr/lib/postgresql/10/bin/pg_ctl stop -m fast -D /var/lib/postgresql/10/main  -o '--config-file=/etc/postgresql/10/main/postgresql.conf' >./nohupstop.out 2>&1"
        sleep 5
        ssh -t postgres@$DBHOST "nohup /usr/lib/postgresql/10/bin/pg_ctl start -D /var/lib/postgresql/10/main  -o '--config-file=/etc/postgresql/10/main/postgresql.conf' >./nohupstart.out 2>&1"
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
        echo -e "Backup Finish at:" ${SCRIPTSTART}"For Database:"$DBHOST"">>$BCK_LOG
        echo -e "Backup ID is:"$BCURID "with Status" $STATUS >>$BCK_LOG
        echo -e "---------------------------------------------------">>$BCK_LOG
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
#----------------------
#fct to insert rows for every backup to local PSQL database
# ----------------------
fctToPSQL()
{
    SIZE=`du -sm $BKPDIR | awk '{print $1}'|sed -e "s/[a-zA-Z/ \-]//g"`
psql -U barman -d barmandb -c "INSERT INTO public.bbackups(sno, bkphost, dbhost, bkpid, status, error, date, dir, size, notify) VALUES (DEFAULT , '{$BKPHOST}', '{$DBHOST}', '{$BCURID}', '{$strSTAT}', '{$ERROR}', current_timestamp, '{$BKPDIR}',$SIZE ,$NOTIFY);"
    psql_exit_status = $?
        if [ $psql_exit_status != 0 ]; then
        echo "psql failed while trying to run this sql script" 1>&2>>$BCK_LOG
        exit $psql_exit_status
        fi
}

fctPhaseChk
