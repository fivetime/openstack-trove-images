# qemu-ga

Installs the QEMU guest agent, so the host can run commands and read files
in a guest through libvirt (`virsh qemu-agent-command`, `guest-exec`)
when the Trove guest agent itself is down. Without it, the only way into
a guest that cannot be logged in to is exporting its root disk.

The agent talks over a virtio-serial channel that Nova adds only when the
image has `hw_qemu_guest_agent=yes`, which `push-to-glance.sh` sets. The
Ubuntu unit is started by udev when that channel appears, so nothing is
enabled here.
