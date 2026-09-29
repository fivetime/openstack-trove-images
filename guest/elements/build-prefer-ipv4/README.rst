build-prefer-ipv4
=================

Makes name resolution inside the image build prefer IPv4, for the duration
of the build only.

The build installs packages inside a chroot with apt and pip. Both ask
``getaddrinfo`` for addresses and try them in the order it returns, IPv6
first. On a build host whose IPv6 egress does not work, every connection
then waits for a timeout before IPv4 is tried: a build that takes fifteen
minutes runs into its ninety minute limit while installing the guest
agent's requirements.

The build host can prefer IPv4 in its own ``/etc/gai.conf`` and still be
affected, because the chroot has its own.

``pre-install.d`` adds the preference to the chroot's ``/etc/gai.conf`` and
``finalise.d`` removes it again, so the image is the same as one built
without this element.
