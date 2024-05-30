# connect the registry to the cluster network if not already connected
#!/bin/sh
set -o errexit

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "kind-registry")" = 'null' ]; then
  docker network connect "kind" "kind-registry"
fi