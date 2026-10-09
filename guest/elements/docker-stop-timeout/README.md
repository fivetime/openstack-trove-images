# docker-stop-timeout

Gives the database container time to stop by itself when the guest shuts
down. Docker's daemon stops its containers with their own stop timeout
(the guest agent creates the database container with Trove's
state_change_wait_time, 180 s), but only within its own shutdown timeout
(15 s by default), and systemd stops the daemon within 90 s: a Galera
member that takes longer is killed, leaves gvwstate.dat behind and comes
back as a crashed member instead of a cleanly stopped one. Both timeouts
are raised to 200 s here, a little more than the container's.
