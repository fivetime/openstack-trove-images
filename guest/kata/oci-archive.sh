#!/bin/bash
# oci-archive.sh <image@sha256:...> <outdir>
#
# Writes the Glance artifact nova-kata takes for a Kata system image
# (openstack-nova-kata doc/source/image_build_guide.rst): an uncompressed
# OCI layout tar, system.oci.tar, and glance-properties.json with
# disk_format raw, container_format bare, hw_kata_containerd_digest (the
# digest of the layout's index.json) and os_admin_user (the Kata layer's
# /usr/share/nova-kata/admin-user). The same steps as the Kata layer's
# own export in openstack-cloud-images (pipelines/oci-system/build.sh).
# Uploading is left to the operator, after the Kata gate.
set -euo pipefail
ref=$1 out=$2
[[ $ref == *@sha256:* ]] || { echo "pass the image by digest" >&2; exit 2; }
[[ ! -e $out ]] || { echo "$out exists" >&2; exit 2; }
mkdir -p "$out"
podman pull -q "$ref" >/dev/null
admin=$(podman run --rm --network none --entrypoint cat "$ref" /usr/share/nova-kata/admin-user)
podman push -q "$ref" "oci:$out/layout:system"
python3 - "$out" "$admin" <<'PY'
import hashlib, json, pathlib, sys, tarfile
out = pathlib.Path(sys.argv[1])
layout = out / "layout"
with tarfile.open(out / "system.oci.tar", "x", format=tarfile.PAX_FORMAT) as archive:
    for path in [layout / "oci-layout", layout / "index.json"] + sorted(
            (layout / "blobs").rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            sys.exit("exported OCI layout contains a special file")
        if path.is_dir():
            continue
        info = archive.gettarinfo(str(path), str(path.relative_to(layout)))
        info.uid = info.gid = info.mtime = 0
        info.uname = info.gname = ""
        info.mode = 0o644
        with path.open("rb") as stream:
            archive.addfile(info, stream)
digest = "sha256:" + hashlib.sha256((layout / "index.json").read_bytes()).hexdigest()
(out / "glance-properties.json").write_text(json.dumps({
    "disk_format": "raw", "container_format": "bare",
    "hw_kata_containerd_digest": digest, "os_admin_user": sys.argv[2]},
    indent=2) + "\n")
PY
rm -r -- "$out/layout"
sha256sum "$out/system.oci.tar" | tee "$out/system.oci.tar.sha256"
cat "$out/glance-properties.json"
