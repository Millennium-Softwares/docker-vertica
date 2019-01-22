#!/bin/bash
set -e

echo " -----> Starting and configuring Vertica"

# Properly shut down Vertica, to avoid inconsistency issues
function vertica_shut_down() {
  echo " -----> Properly shut down Vertica"
  /bin/su - dbadmin -c '/opt/vertica/bin/vsql -d database -c "SELECT CLOSE_ALL_SESSIONS();"'
  /bin/su - dbadmin -c '/opt/vertica/bin/vsql -d database -c "SELECT MAKE_AHM_NOW();"'
  /bin/su - dbadmin -c '/opt/vertica/bin/admintools -t stop_db -d database -i'
  echo " -----> Vertica has now shutdown"
}

function vertica_shut_down_proper() {
  echo " ----->  Shutting down Vertica completely"
  /bin/su - dbadmin -c '/opt/vertica/bin/vsql -d database -c "SELECT CLOSE_ALL_SESSIONS();"'
  /bin/su - dbadmin -c '/opt/vertica/bin/vsql -d database -c "SELECT MAKE_AHM_NOW();"'
  /bin/su - dbadmin -c '/opt/vertica/bin/admintools -t stop_db -d database -i'
  echo " -----> Vertica has now shutdown"
  exit
}

# Intercept closing of container and proper shut down Vertica
trap "vertica_shut_down_proper" SIGKILL SIGTERM SIGHUP SIGINT EXIT

# Function to handle Vertica DB Restore (Working on...)
importdb(){
    echo " -----> Restoring database"
    rm -rf /srv/vertica/db/tempbak
    mkdir -p /srv/vertica/db/tempbak
    mv /srv/vertica/db/data /srv/vertica/db/tempbak
    mv /srv/vertica/db/catalog /srv/vertica/db/tempbak
    echo " -----> Create fake db, just to initialize Vertica"
    su - dbadmin -c "/opt/vertica/bin/admintools -t create_db -s localhost --skip-fs-checks -d database -c /srv/vertica/db/catalog -D /srv/vertica/db/data"
    vertica_shut_down
    rm -R  /srv/vertica/db/data
    rm -R /srv/vertica/db/catalog
    mv /srv/vertica/db/tempbak/* /srv/vertica/db
    rm -R /srv/vertica/db/tempbak
    su - dbadmin -c "/opt/vertica/bin/admintools -t start_db -d database -i"
}


if [ -z "$(ls -A "/srv/vertica/db/data")" ]; then
  # If not data exists, create folders. Then, check DB existence
  mkdir -p /srv/vertica/db/catalog
  mkdir -p /srv/vertica/db/data
  chown -R dbadmin:verticadba "/srv/vertica/db"
  if [[ ! $(su - dbadmin -c "/opt/vertica/bin/admintools -t list_allnodes" | grep vertica) ]]; then
    # No database available -> Create one
    echo " -----> Creating an empty DB"
    su - dbadmin -c "/opt/vertica/bin/admintools -t create_db -s localhost --skip-fs-checks -d database -c /srv/vertica/db/catalog -D /srv/vertica/db/data"
  else
    # Database available but no data on folder -> Delete and create new one
    echo " -----> Delete empty DB before create a new one"
    su - dbadmin -c "/opt/vertica/bin/admintools -t drop_db -d database"
    su - dbadmin -c "/opt/vertica/bin/admintools -t create_db -s localhost --skip-fs-checks -d database -c /srv/vertica/db/catalog -D /srv/vertica/db/data"
  fi
else
  if [[ ! $(su - dbadmin -c "/opt/vertica/bin/admintools -t list_allnodes" | grep vertica) ]]; then
    # Database not available but data in folder -> Try to import

    if [[ "$NODE_TYPE" -ne "master" ]]
    then
      importdb
    fi
    # Unable to import from row data -> Inconsistent Epoch state -> So, delete data and create new DB
    # echo " -----> Remove old DB data and create an empty one"
    #rm -rf /srv/vertica/db/*
    #su - dbadmin -c "/opt/vertica/bin/admintools -t create_db -s localhost --skip-fs-checks -d database -c /srv/vertica/db/catalog -D /srv/vertica/db/data"
  else
    # We have both data and DB -> Just start
    echo " -----> DB and data available, just start DB"
    su - dbadmin -c "/opt/vertica/bin/admintools -t start_db -d database -i"
  fi
fi

echo " -----> Vertica is now running"

if [[ "$NODE_TYPE" == "master" ]]
then
  echo " -----> Now setting the nodes"

  if [[ ! -d "/opt/vertica/bin" ]]
  then
    echo "Installing RPM on this node..."
    rpm -Uvh /tmp/vertica.rpm
  fi
  echo "The RPM is installed."

  if [[ ! -e /opt/vertica/bin/admintools.conf ]]
  then
    LICENSE="CE"
    if [[ -f "/tmp/license.dat" ]]
    then
      LICENSE="/tmp/license.dat"
    fi

    echo "Setting up a Vertica cluster from this master node... License : $LICENSE"

    INSTALL_COMMAND="/opt/vertica/sbin/install_vertica \
      --rpm /tmp/vertica.deb \
      --no-system-configuration \
      --license "$LICENSE" \
      --accept-eula \
      --dba-user dbadmin \
      --dba-user-password-disabled \
      --failure-threshold NONE \
      --point-to-point \
      --ignore-aws-instance-type"

    if [[ ! -z "$VERTICA_LARGE_CLUSTER" ]]
    then
      INSTALL_COMMAND="$INSTALL_COMMAND --large-cluster $VERTICA_LARGE_CLUSTER"
    fi

    echo "RUNNING $INSTALL_COMMAND"
    eval $INSTALL_COMMAND
  fi
  echo "The cluster is set up."

  # Sets up a cluster (a set of nodes sharing the same spread configuration)
  if ! su - dbadmin -c "/opt/vertica/bin/admintools -t view_cluster" | grep -q docker
  then
    echo "Now creating the database..."
    su - dbadmin -c "/opt/vertica/bin/admintools \
      -t create_db \
      -s "$CLUSTER_NODES" \
      -d docker \
      -c /srv/vertica/db/catalog \
      -D /srv/vertica/db/data \
      --skip-fs-checks"
  fi
  echo "The docker database has been created on the cluster."
fi

# Start Vertica Console service
echo " -----> Starting Vertica Console"
/etc/init.d/vertica-consoled start
echo " -----> Vertica Console is now running"

# Hang session
while true; do
  sleep 1
done
