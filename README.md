# podman-rootless-veth

Rootless Podman containers with a real IP address (veth + bridge + DHCP) instead of pasta.
Containers start with `--network none`; an OCI hook asks a user-level systemd service to
create a veth pair via `lxc-user-nic` and get an address with `udhcpc`.

Details and explanations (in Russian): **[article link](https://jgivc.ru/blog/podman-rootless-network/)**

Tested on Debian 13 (no NetworkManager). Root is required for the one-time host setup only.

## Layout

The tree mirrors the host filesystem and assumes the user is called `user`.

```
etc/
├── dnsmasq.conf
├── nftables.conf
├── lxc/lxc-usernet
├── network/interfaces.d/br0
└── sysctl.d/ip_forward.conf
home/user/
├── bin/
│   ├── dhcp.sh                  # Alpine's udhcpc default.script + 1-line patch (see article)
│   ├── netd-handler.sh          # Executed when a systemd socket is triggered
│   └── podman_netd_hook.sh      # Triggered by a hook
├── host3/                       # Example pod configutation files
│   ├── host3.yml
│   └── banner2-http-d/default.conf
└── .config/
    ├── containers/
    │   ├── containers.conf
    │   ├── oci/hooks.d/netd.json
    │   └── systemd/
    │       ├── host2.container  # example: single container
    │       └── host3.kube       # example: pod
    └── systemd/user/
        ├── netd.socket
        └── netd@.service
```

## Install

> **Warning:** the files in `etc/` replace system configs (`nftables.conf`, `dnsmasq.conf`, network setup).
> Use a clean machine (VM), or review each file and merge it by hand. Don't copy blindly.

1. Install packages:

   ```bash
   sudo apt update
   sudo apt --no-install-recommends install git podman catatonit \
     dnsmasq jq bridge-utils curl uidmap liblxc-common busybox git
   ```

2. Clone the repository:

   ```bash
   git clone https://github.com/<you>/podman-rootless-veth.git
   cd podman-rootless-veth
   ```

3. **Replace `user` with your username** in all files:

   ```bash
   grep -rlE '/home/user|^user ' etc home | xargs sed -i "s|/home/user|$HOME|g; s|^user |$USER |"
   ```

4. **Read before you copy.** The files in `etc/` replace or extend system-wide settings
   (`nftables.conf` starts with `flush ruleset` and wipes all firewall rules; `dnsmasq.conf` takes over
   DNS and DHCP; `br0` adds a network bridge).
   - On a **clean machine or VM**: copy them as is, only set `container_net_oif` in `nftables.conf`
     to your real uplink interface (it's not always `eth0`).
   - On a **configured system**: don't copy. Read each file and merge the needed parts by hand.

5. Copy the files and make the scripts executable:

   ```bash
   cp -rv home/user/. ~/
   chmod +x ~/bin/*.sh
   sudo cp -rv etc/. /etc/    # clean machine only, see step 4
    ```

6. Apply the host configuration:

   ```bash
   sudo sysctl -p /etc/sysctl.d/ip_forward.conf
   sudo ifup br0
   echo 'nameserver 127.0.0.1' | sudo tee /etc/resolv.conf   # so the host can resolve container names
   sudo dnsmasq --test && sudo systemctl restart dnsmasq
   sudo systemctl enable --now nftables
   # Check rules
   sudo nft -n -a list ruleset
   ```

7. Enable the user socket:

   ```bash
   # If you are configuring it for someone other than the current user
   # loginctl enable-linger "$USER"
   systemctl --user daemon-reload
   systemctl --user enable --now netd.socket
   ```

## Usage

```bash
podman run -it --rm --network none --annotation "netd.use=true" \
  --hostname host1 --entrypoint /bin/sh alpine:latest
```

Via systemd (Quadlet):

```bash
systemctl --user daemon-reload
systemctl --user start host2   # container
systemctl --user start host3   # pod
```

Check from the host: `ping host1`, `curl host2`, `curl host3`, `curl host3:81`
Verify that the containers are accessible to each other by name.

## Limitations

- The DHCP lease is not renewed or released (the client exits after getting an address).
- `--dns`, `--add-host` and other network options don't work with `--network none`.
- IPv4 only. Limit of veth devices per user is set in `/etc/lxc/lxc-usernet`.

## License

This project is licensed under the MIT License (see LICENSE).
Note: This repository contains a modified version of default.script from Alpine Linux (located at dhcp.sh), which is licensed under the GNU General Public License v2.0.
