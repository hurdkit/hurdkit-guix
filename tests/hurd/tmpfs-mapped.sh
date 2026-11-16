#!/bin/sh
# Exercise the already-installed /dev/shm translator and an ext2 control.
set -eu
shm-unlink /dev/shm
shm-unlink --anon
shm-unlink /tmp
tmpfs-io /dev/shm
tmpfs-lifetime /dev/shm 100
