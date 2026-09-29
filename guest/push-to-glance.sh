#!/usr/bin/env bash
# Upload a Trove guest image to Glance.
#
# Usage: push-to-glance.sh <image-file> <name> <trove-commit>
#
# The image is converted to raw first: this cloud's Glance default store is
# RBD, and Cinder/Nova only clone copy-on-write from raw images.
#
# Trove boots database instances in the service project with its own
# service user, so the image is private and owned by that project; tenants
# never see it. Datastore versions select it by the "trove" and "fivetime"
# image tags rather than by ID, so each new build is used for new instances
# without re-registering anything.
#
# Environment: the usual OS_* variables for an admin user, plus
#   SERVICE_PROJECT         project that owns the image (default: service)
#   SERVICE_PROJECT_DOMAIN  its domain (default: service). openstack-helm
#                           puts service users and their project in the
#                           "service" domain, and a same-named project in
#                           Default makes a bare name ambiguous.
#   KEEP             older builds of the same name to keep (default: 2)

set -Eeuo pipefail

src=${1:?image file}
name=${2:?image name}
commit=${3:?trove commit}
SERVICE_PROJECT=${SERVICE_PROJECT:-service}
SERVICE_PROJECT_DOMAIN=${SERVICE_PROJECT_DOMAIN:-service}
KEEP=${KEEP:-2}

raw=${src%.*}.raw
if [[ "$src" != "$raw" ]]; then
    qemu-img convert -p -O raw "$src" "$raw"
fi

owner=$(openstack project show --domain "$SERVICE_PROJECT_DOMAIN" \
    "$SERVICE_PROJECT" -f value -c id)

id=$(openstack image create "$name" \
    --disk-format raw --container-format bare \
    --private --project "$owner" \
    --file "$raw" \
    --tag trove --tag fivetime \
    --property hw_rng_model=virtio \
    --property hypervisor_type=qemu \
    --property os_distro=ubuntu \
    --property trove_commit="$commit" \
    -f value -c id)
echo "uploaded $name as $id (trove $commit)"

status=$(openstack image show "$id" -f value -c status)
if [[ "$status" != "active" ]]; then
    echo "image $id is $status, expected active" >&2
    exit 1
fi

# Prune older builds of the same name, newest first, keeping the one just
# uploaded plus KEEP. Glance refuses to delete an image that still backs RBD
# clones, so a failed delete is reported and skipped.
mapfile -t old < <(openstack image list --private --tag trove --tag fivetime \
    --name "$name" --sort created_at:desc -f value -c ID | tail -n +$((KEEP + 2)))
for o in "${old[@]}"; do
    openstack image delete "$o" || echo "kept $o: still in use"
done
