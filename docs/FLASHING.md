# Flashing the Beryl 7, upgrading, and getting back to stock

About 10 minutes. The first flash goes through GL.iNet's recovery page, which lives in the router's
bootloader and survives any firmware, so you can always go back to stock the same way.

## You need

- A computer with an Ethernet port or a USB Ethernet adapter, and a cable.
- The image: `openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin` from your build (see
  the README). Note its SHA-256 (`sha256sum` or `shasum -a 256`).
- A USB-C charger that does 9 V or more (the one in the box is fine). At 5 V the router runs but its USB
  port gets no power.
- GL.iNet's own firmware for the GL-MT3600BE (from GL.iNet's download page), in case you want to go back.

## Flash

1. Unplug the router's power. Plug the cable into its **LAN** port (the ports are labelled on the case).
2. Give the computer a fixed address on that port **before** plugging the cable in: `192.168.1.10`, mask
   `255.255.255.0`, **router left empty**. With a router address set, some computers move their internet
   onto the cable, where there is none.
3. Hold the reset button, plug the power back in, keep holding for about 5 seconds, then let go.
4. Open `http://192.168.1.1`. GL.iNet's recovery page appears. Choose the `.bin` file and upload it. The
   page shows the file's size and MD5 before it writes anything: compare them with your file, then start
   the update. Don't unplug anything while it runs (about 3 minutes; it reboots by itself).
5. To reach the new firmware over the same cable, change the computer's address to `172.31.77.10` (still
   no router), or set it back to automatic: the router hands out addresses on its LAN.

## First start

The first boot takes 2 to 3 minutes while it sets itself up.

- Open `http://172.31.77.1` (the LAN is moved off `192.168.1.1`, which clashes with many hotel networks).
  User `root`, no password on a fresh image: set one under System → Administration.
- The travel panel is the first page. Wi-Fi is off on a fresh image: under **Your Wi-Fi**, set a name and
  a password; that turns on both bands with WPA2/WPA3.
- To use Tailscale exit nodes, plug the router's **WAN** port into a network with internet, then in the
  panel open More → Tailscale → Log in.

## From one build to the next, keeping settings

No cable and no reset button: the running firmware writes the new image itself (`sysupgrade`). It keeps
everything `sysupgrade -l` lists: the settings, Wi-Fi and saved networks, the Tailscale login, SSH keys and
the root password. **It empties `/root`**: copy anything you keep there first.

1. Copy the image to the router: `scp -O <image> root@<router>:/tmp/`, and compare
   `sha256sum /tmp/<image>` with your file.
2. `sysupgrade -T /tmp/<image>`: checks the image fits this router, writes nothing.
3. `sysupgrade -v /tmp/<image>`: writes it and reboots. Back on the network in about a minute or two.
4. `cat /etc/beryl7-image` shows which build is running.

If it does not come back, the recovery page above takes any image, the previous one included; that one
needs hands on the reset button, so upgrade while you can reach the router.

## Back to stock

Same recovery page, same steps, but upload GL.iNet's own firmware for the GL-MT3600BE. Keep that file on
your laptop while travelling.

## If something goes wrong

- The recovery page doesn't appear: hold reset longer (up to 10 s) while powering on, and check the
  computer really has `192.168.1.10`.
- The router boots but you cannot find its Wi-Fi: Wi-Fi is off until you set a password. Plug the computer
  into LAN, set it to automatic, open `http://172.31.77.1`.
- Anything odd: the recovery page always works, and stock firmware is always one upload away.
