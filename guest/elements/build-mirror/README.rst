build-mirror
============

Lets the image be built from a nearby Ubuntu mirror without the mirror
ending up in the image.

``DIB_DISTRIBUTION_MIRROR`` is where debootstrap and apt fetch packages
during the build, and ``ubuntu-minimal`` writes that same URL into the
image's ``/etc/apt/sources.list``. From the build host the default,
http://archive.ubuntu.com/ubuntu, has at times slowed to one package a
minute, and the build hit its ninety minute limit while debootstrap was
still retrieving the base system.

With this element the build fetches from ``DIB_DISTRIBUTION_MIRROR`` as
usual, and ``finalise.d`` rewrites every ``deb`` line of
``/etc/apt/sources.list`` to ``DIB_BUILD_MIRROR_IMAGE`` (default
http://archive.ubuntu.com/ubuntu) and drops the package lists fetched from
the build mirror, so the image is the same as one built from the default.
