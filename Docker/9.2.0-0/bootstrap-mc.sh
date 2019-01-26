#!/bin/bash

set -e

# Start Vertica Console service
echo " -----> Starting Vertica Console"
/etc/init.d/vertica-consoled start
echo " -----> Vertica Console is now running"

tail -f /var/log/dmesg
