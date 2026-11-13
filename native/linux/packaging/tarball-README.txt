pux for Linux (x86-64, glibc 2.35 or later)
===========================================

Run it from this directory:

    ./pux

pux links libsodium statically. Its other libraries come from the system;
desktop installs usually have most of them already.

  Needs                                   Library this build links
  GTK 3 (3.24 or later) and GLib          libgtk-3.so.0, libglib-2.0.so.0
  libsecret 0.20 or later                 libsecret-1.so.0
  libcurl                                 libcurl.so.4
  OpenSSL 3                               libssl.so.3, libcrypto.so.3

Install what is missing:

  Debian, Ubuntu:  sudo apt install libgtk-3-0 libsecret-1-0 libcurl4 libssl3
  Fedora:          sudo dnf install gtk3 libsecret libcurl openssl-libs
  Arch:            sudo pacman -S gtk3 libsecret curl openssl

On Debian and Ubuntu the .deb package installs these for you.

Check what is missing:

    ldd ./pux | grep "not found"

This build was linked on Ubuntu 22.04 against the library versions named above.
A distribution that ships a newer or older major version of one of them (for
example OpenSSL with a different soname) does not provide the
file this build asks for, even with the package installed, and ldd reports it as
"not found". In that case use the .deb package on a Debian-based system, or
build pux from source (native/linux/README.md in the repository).

pux also needs, running in your desktop session:

  - A Secret Service keyring: GNOME Keyring, KWallet or KeePassXC with Secret
    Service integration turned on. pux keeps its keys there and will not start
    without one.
  - A notification service (org.freedesktop.Notifications) to show codes.

https://github.com/vidurb/pux
