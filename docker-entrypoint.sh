#!/bin/sh
set -e

# allow re-using the instance - https://stackoverflow.com/a/38732187/2866660
if [ -f tmp/pids/server.pid ]; then
  rm tmp/pids/server.pid
fi

if [ ! -z "${FOODSOFT_DB_PREFIX}" ] || [ ! -z "${FOODSOFT_DB_PREFIX_FILE}" ]; then
    echo "Getting list of foodcoop dbs"
    FOODSOFT_FOODCOOPS=`BUNDLE_CONFIG=/dev/null bundle exec ruby script/list_databases`
fi

FOODSOFT_FOODCOOPS_REGEX=`echo $FOODSOFT_FOODCOOPS | sed 's/ /|/g'`

sed -i "s/__FOODCOOPS__/$FOODSOFT_FOODCOOPS_REGEX/g" config/routes.rb
for plugin in $(ls plugins); do
    echo "WARNING: modifying routes.rb for $plugin"
    if [ -f "plugins/$plugin/config/routes.rb" ]; then
        sed -i "s/__FOODCOOPS__/$FOODSOFT_FOODCOOPS_REGEX/g" plugins/$plugin/config/routes.rb
    fi
done


if [ -e app_config.defaults.yml ] ; then
  cat app_config.defaults.yml > config/app_config.yml

  for FOODCOOP in $FOODSOFT_FOODCOOPS; do
    echo "Adding config for foodcoop $FOODCOOP"
    cat << EOF >> config/app_config.yml
$FOODCOOP:
  <<: *defaults
  database:
    database: foodsoft_$FOODCOOP
EOF
  done
fi

exec gosu nobody:nogroup "$@"
