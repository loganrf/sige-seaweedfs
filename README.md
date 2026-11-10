# sige-seaweedfs

A Proxmox VE recipe for a [SeaweedFS](https://github.com/seaweedfs/seaweedfs) LXC container.

The recipe is one Bash script. You run the script on a Proxmox VE host. A wizard asks for the
settings. Then a review screen shows all the settings. You can change each setting before the
recipe makes the container.

The recipe does these steps:

1. It downloads the newest Debian standard template.
2. It makes an LXC container (unprivileged by default) with a separate data disk.
3. It installs the `weed` program from the SeaweedFS release page and checks the MD5 checksum.
4. It writes the SeaweedFS settings, the S3 credentials and the systemd services.
5. It starts SeaweedFS, makes the S3 buckets and shows the endpoints and credentials.

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [The wizard](#the-wizard)
- [Wizard steps](#wizard-steps)
- [Roles and clusters](#roles-and-clusters)
- [Unattended mode](#unattended-mode)
- [After the installation](#after-the-installation)
- [Security](#security)
- [Command-line options](#command-line-options)
- [Troubleshooting](#troubleshooting)

## Requirements

- Proxmox VE 8 or 9. Debian 13 templates need a Proxmox VE release that supports Debian 13.
  On an older host, select Debian 12.
- A root shell on the Proxmox VE host.
- Internet access for the host (templates) and for the container (`github.com`).
- `whiptail` for the wizard. Proxmox VE includes `whiptail`.

## Quick start

Open a shell on the Proxmox VE host as root. Enter this command:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/loganrf/sige-seaweedfs/refs/heads/main/create_instance.sh)"
```

You can also use `curl`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/loganrf/sige-seaweedfs/refs/heads/main/create_instance.sh)"
```

To see the commands before the recipe changes the host, download the script and use `--dry-run`:

```bash
wget -q https://raw.githubusercontent.com/loganrf/sige-seaweedfs/refs/heads/main/create_instance.sh
```

```bash
bash create_instance.sh --dry-run
```

## The wizard

The first screen has two modes:

| Mode | What it does |
|---|---|
| **Quick** | Uses the recommended settings and goes directly to the review screen. |
| **Advanced** | Shows each important setting, step by step. Then it shows the review screen. |

Each step shows a default value. To accept the default, press **Enter**.

| Key | Function |
|---|---|
| **Enter** | Accept the value and go to the next step (**Next**). |
| **Tab** | Move to the buttons. Select **Back** to go to the previous step. |
| **Space** | Select or clear an item in a check list. |
| **Esc** | Go back. On the first screen, stop the wizard. |

### The review screen

The review screen shows all the settings in groups. Each line shows the current value.

- To change a setting, select the line. The recipe opens the step for that setting.
  If a change makes other settings necessary, the recipe opens those steps too.
  For example, a change to a static IPv4 address opens the address and gateway steps.
- Some expert settings are only on the review screen. Examples: the ports, the DNS servers,
  the volume index and the extra `weed` arguments.
- Select **Make the container with these settings** to continue. The recipe checks all the
  settings first. If a setting is not correct, the recipe shows the problem.
- Select **Save the answers to a file** to keep the settings for later. The file does not
  contain secrets. Use the file with `--config` to make similar containers.

## Wizard steps

The "Shown" column tells where the step is:

- **W+R**: in the Advanced wizard and on the review screen.
- **R**: on the review screen only (expert setting).

The answer key is the name of the setting in an answers file.

### SeaweedFS role and container

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Role | `SWFS_ROLE` | `all-in-one` | W+R | `all-in-one`, `master`, `volume` or `filer`. Refer to [Roles and clusters](#roles-and-clusters). |
| Container ID | `CT_ID` | next free ID | W+R | The recipe checks that no guest of the cluster uses the ID. |
| Host name | `CT_HOSTNAME` | `seaweedfs` | W+R | For the other roles, the default is `seaweedfs-<role>`. |
| Operating system | `CT_OS` | `debian-13` | W+R | `debian-13` or `debian-12`. |
| Template storage | `CT_TEMPLATE_STORAGE` | `local` | W+R | The wizard shows this step only if there is more than one template storage. |
| Tags | `CT_TAGS` | `seaweedfs` | R | Proxmox tags, separated by semicolons. |

### Resources

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Root disk storage | `CT_ROOTFS_STORAGE` | `local-lvm` or `local-zfs` | W+R | The menu shows the type and the free space of each storage. |
| Root disk size | `CT_ROOTFS_SIZE` | `8` GiB | W+R | Debian and SeaweedFS use approximately 2 GiB. |
| CPU cores | `CT_CORES` | `2` | W+R | |
| Memory | `CT_MEMORY` | `2048` MiB | W+R | The `memory` volume index keeps an entry for each file in RAM. |
| Swap | `CT_SWAP` | `512` MiB | W+R | |

### Data storage

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Data location | `DATA_MODE` | `volume` | W+R | `volume`: a new disk on a Proxmox storage. `bind`: a host directory. `rootfs`: a directory on the root disk. |
| Data disk storage | `DATA_STORAGE` | the root disk storage | W+R | For `volume` only. |
| Data disk size | `DATA_SIZE` | `64` GiB (`8` for master and filer) | W+R | For `volume` only. |
| Host directory | `DATA_HOST_PATH` | none | W+R | For `bind` only. The recipe makes the directory and sets its owner to the `seaweedfs` user of the container. |
| Back up data disk | `DATA_BACKUP` | yes | W+R | For `volume` only. Proxmox backups do not include a bind mount. |
| Data path in container | `DATA_MOUNT` | `/data` | R | |

### Network

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Bridge | `NET_BRIDGE` | `vmbr0` | W+R | The menu shows the bridges of the host. |
| IPv4 mode | `NET_IP` | `dhcp` | W+R | `dhcp` or static. A master needs an address that does not change. |
| IPv4 address | `NET_IP` | none | W+R | For a static address only. CIDR format, for example `192.168.1.50/24`. |
| IPv4 gateway | `NET_GW` | the gateway of the host | W+R | For a static address only. |
| VLAN tag | `NET_VLAN` | none | W+R | 1 to 4094. |
| IPv6 | `NET_IP6` | `none` | R | `none`, `auto` (SLAAC) or `dhcp`. |
| DNS servers | `NET_DNS` | the host settings | R | |
| DNS search domain | `NET_SEARCHDOMAIN` | the host settings | R | |

### Access

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Root password | `CT_PASSWORD` | random | W+R | 8 or more characters. The recipe shows the password at the end. |
| SSH public key | `CT_SSH_KEY_FILE` | none | W+R | A key file on the host, for example `/root/.ssh/authorized_keys`. |
| Container options | `CT_UNPRIVILEGED`, `CT_ONBOOT` | unprivileged, start at boot | W+R | A check list. |

### SeaweedFS

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| SeaweedFS version | `SWFS_VERSION` | `latest` | W+R | Or a release number, for example `4.53`. |
| Build | `SWFS_VARIANT` | `standard` | W+R | `standard`, `large_disk`, `full` or `full_large_disk`. A volume larger than 30000 MB needs a `large_disk` build. |
| Master address | `SWFS_MASTER` | none | W+R | For the `volume` and `filer` roles. `host:port`, separated by commas. |
| Master peers | `SWFS_PEERS` | none | R | For 3 highly available masters. |
| Advertised address | `SWFS_ADVERTISE` | the static IPv4 address | R | The `weed -ip` option. With DHCP, SeaweedFS finds the address when it starts. |
| Replication | `SWFS_REPLICATION` | `000` | W+R | For the `all-in-one` and `master` roles. Each copy needs a different volume server. |
| Data center | `SWFS_DATACENTER` | none | R | For replication. |
| Rack | `SWFS_RACK` | none | R | For replication. |

### Storage tuning

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Volume size limit | `SWFS_VOLUME_SIZE_MB` | automatic | W+R | Blank: 1% of the data disk, rounded up to a power of 2, from 64 MB to 1024 MB. `weed mini` uses the same rule. |
| Maximum volumes | `SWFS_VOLUME_MAX` | `0` | R | `0`: calculate from the free disk space. |
| Volume index | `SWFS_INDEX` | `memory` | R | `leveldb` uses less RAM. |
| Disk type tag | `SWFS_DISK_TYPE` | none (`hdd`) | R | `hdd`, `ssd` or a custom tag. |

SeaweedFS keeps files in volumes. Each S3 bucket uses its own volumes. The upstream default volume
size is 30000 MB. On a small disk, this default allows only a few volumes. Thus, the recipe
calculates a smaller size from the disk size.

### Services

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Services | `SWFS_FILER`, `SWFS_S3`, `SWFS_WEBDAV`, `SWFS_ADMIN`, `SWFS_METRICS`, `SWFS_ICEBERG`, `SWFS_TELEMETRY` | filer, S3, admin UI | W+R | A check list. The list shows only the services of the role. |
| S3 access key | `SWFS_S3_ACCESS_KEY` | random | R | |
| S3 secret key | `SWFS_S3_SECRET_KEY` | random | R | |
| S3 buckets | `SWFS_BUCKETS` | none | W+R | Names separated by commas, for example `backups,media`. |
| Admin user | `SWFS_ADMIN_USER` | `admin` | R | |
| Admin password | `SWFS_ADMIN_PASSWORD` | random | W+R | |
| Extra weed arguments | `SWFS_EXTRA_ARGS` | none | R | Example: `-volume.minFreeSpace=10GiB`. |

Telemetry is off by default. SeaweedFS turns telemetry on by default. The recipe adds
`-telemetry=false` until you select the telemetry item.

### Ports

All the port steps are on the review screen only (R). The master, volume, filer, S3 and admin
services also use the port + 10000 for gRPC. The recipe checks that no two services use the
same port.

| Service | Answer key | Default | gRPC port |
|---|---|---|---|
| Master | `PORT_MASTER` | `9333` | `19333` |
| Volume server | `PORT_VOLUME` | `8080` | `18080` |
| Filer | `PORT_FILER` | `8888` | `18888` |
| S3 gateway | `PORT_S3` | `8333` | `18333` |
| WebDAV gateway | `PORT_WEBDAV` | `7333` | |
| Admin web UI | `PORT_ADMIN` | `12535` | `22535` |
| Metrics | `PORT_METRICS` | `9327` | |
| Iceberg catalog | `PORT_ICEBERG` | `8181` | |
| Lance namespace | `PORT_LANCE` | `9101` | |

### Firewall

| Step | Answer key | Default | Shown | Notes |
|---|---|---|---|---|
| Proxmox firewall | `FW_ENABLE` | off | W+R | The rules let in only the ports of the selected services. |
| Allowed sources | `FW_SOURCE` | the subnet of the container | W+R | IPv4 addresses or CIDR values, separated by commas. Blank: all addresses. |
| Allow SSH | `FW_SSH` | yes | R | |

The firewall of a container operates only if the firewall is on at the datacenter level
(**Datacenter > Firewall > Options**). The recipe does not change the datacenter firewall.
If the datacenter firewall is off, the recipe shows a warning.

## Roles and clusters

| Role | Services | Use |
|---|---|---|
| `all-in-one` | master, volume server, filer, S3, WebDAV, admin UI | One container for a home lab or a small site. |
| `master` | master, admin UI | The cluster map. Make 1 or 3 masters. |
| `volume` | volume server | File data. Make one container for each disk or host. |
| `filer` | filer, S3, WebDAV, admin UI | Directories, S3 and WebDAV. |

To make a cluster, do the steps that follow:

1. Make the master. Use a static IPv4 address.

   ```bash
   ./create_instance.sh --unattended --set SWFS_ROLE=master --set NET_IP=192.168.1.50/24 --set SWFS_REPLICATION=001
   ```

2. Make two or more volume servers. Point them to the master.

   ```bash
   ./create_instance.sh --unattended --set SWFS_ROLE=volume --set SWFS_MASTER=192.168.1.50:9333 --set DATA_SIZE=500
   ```

3. Make the filer. Point it to the master.

   ```bash
   ./create_instance.sh --unattended --set SWFS_ROLE=filer --set SWFS_MASTER=192.168.1.50:9333 --set SWFS_BUCKETS=backups
   ```

Replication `001` keeps two copies on different volume servers. Thus, it needs two or more
volume servers.

An `all-in-one` container can also be the master of more volume servers.

## Unattended mode

Use an answers file to make a container with no questions. The file has one `KEY="value"` line
for each setting. [`answers.example`](answers.example) shows all the keys, their defaults and
a description.

1. Copy the example file.

   ```bash
   cp answers.example my.answers
   ```

2. Edit the values in `my.answers`.
3. Make the container.

   ```bash
   ./create_instance.sh --unattended --config my.answers
   ```

More information:

- `--set KEY=VALUE` changes one answer. `--set` values replace the values from the file.
- Without `--unattended`, the wizard starts with the values from the file as the defaults.
- `--save FILE` writes the answers to a file and stops. The file does not contain secrets.
- The recipe checks all the answers before it changes the host. If an answer is not correct,
  the recipe shows the problem and stops.
- A blank secret gets a random value.

The recipe also writes the answers of each container to `/etc/seaweedfs/recipe.answers` in the
container. To make a similar container, copy that file to the host and set `CT_ID=""`.

## After the installation

At the end, the recipe shows the endpoints and the credentials. The recipe also writes the
endpoints to the **Notes** of the container in the Proxmox web interface.

### Files in the container

| Path | Content |
|---|---|
| `/etc/seaweedfs/seaweedfs.args` | The arguments of the main `weed` command, one on each line. |
| `/etc/seaweedfs/admin.args` | The arguments of the admin web UI. |
| `/etc/seaweedfs/admin.env` | The admin password (`WEED_ADMIN_PASSWORD`). Mode `0600`. |
| `/etc/seaweedfs/s3.json` | The S3 identities and keys. Mode `0640`. |
| `/etc/seaweedfs/filer.toml` | The filer metadata store (LevelDB in `<data>/filer`). |
| `/etc/seaweedfs/recipe.answers` | The answers that made the container. No secrets. |
| `/root/seaweedfs-credentials.txt` | The S3 keys and the admin password. Mode `0600`. |
| `<data>/master`, `<data>/volume`, `<data>/filer`, `<data>/admin` | The SeaweedFS data. |
| `/usr/local/bin/weed` | The SeaweedFS program. |
| `/usr/local/sbin/seaweedfs-launch` | Starts `weed` with the arguments of an `.args` file. |
| `/usr/local/sbin/seaweedfs-update` | Updates the `weed` program. |

The services are `seaweedfs.service` and `seaweedfs-admin.service`. They run as the
`seaweedfs` user.

### Change the settings

1. Open a shell in the container.

   ```bash
   pct enter <ctid>
   ```

2. Edit `/etc/seaweedfs/seaweedfs.args`. Write one argument on each line. To see all the options,
   enter `weed help server` (or `master`, `volume`, `filer`).
3. Restart the service.

   ```bash
   systemctl restart seaweedfs
   ```

To add an S3 user, edit `/etc/seaweedfs/s3.json`. Then restart the service.

### Update SeaweedFS

```bash
pct exec <ctid> -- seaweedfs-update
```

To install a specific release, add the release number, for example `seaweedfs-update 4.53`.
The update keeps the build type (`standard`, `large_disk` ...) of the installation.

### See the logs

```bash
pct exec <ctid> -- journalctl -u seaweedfs -u seaweedfs-admin -f
```

### Use the S3 gateway

The S3 gateway uses path-style addresses. Set the access key and the secret key from
`/root/seaweedfs-credentials.txt` in your S3 client. An example for the AWS CLI:

```bash
AWS_ACCESS_KEY_ID=<access-key> AWS_SECRET_ACCESS_KEY=<secret-key> aws --endpoint-url http://<container-ip>:8333 s3 ls
```

## Security

- The S3 gateway needs the access key. The admin web UI needs the admin password.
- The master, volume and filer HTTP ports have no password. The WebDAV gateway has no password.
  Keep these ports on a trusted network, or turn on the Proxmox firewall (`FW_ENABLE=1`).
- The recipe uses an unprivileged container by default.
- The recipe gives the root password to `chpasswd` through standard input. The password is not
  in the process list of the host.
- The recipe gives the admin password to `weed admin` through an environment file. The password
  is not in the process list of the container.
- The recipe checks the MD5 checksum of the downloaded release. SeaweedFS publishes an MD5 file for
  each release file.

## Command-line options

| Option | Function |
|---|---|
| `-c`, `--config FILE` | Read the answers from `FILE`. |
| `-s`, `--set KEY=VALUE` | Set one answer. You can use this option more than once. |
| `-u`, `--unattended` | Do not start the wizard. Use the defaults and the answers. |
| `-n`, `--dry-run` | Show the commands. Do not change the host. |
| `--save FILE` | Write the answers to `FILE`, then stop. |
| `-h`, `--help` | Show the help. |
| `-V`, `--version` | Show the recipe version. |

## Troubleshooting

| Problem | Cause and correction |
|---|---|
| "No Debian 13 template is available" | The host does not have the Debian 13 template list. Enter `pveam update`, or set `CT_OS=debian-12`. |
| "The container cannot resolve github.com" | The container has no network. Check the bridge, the VLAN tag, the IP address and the DNS servers. |
| A service "does not answer" | Examine the log: `journalctl -u seaweedfs`. Correct `/etc/seaweedfs/seaweedfs.args`, then restart the service. |
| A volume server does not join the master | Check `SWFS_MASTER` and the firewall of the master (ports 9333 and 19333). |
| Uploads to a new bucket fail, and the log tells that no writable volume is available | Each bucket needs volumes. Use a smaller volume size limit (`-master.volumeSizeLimitMB`), or add disk space. |
| The setup stops after the container exists | The recipe shows the commands to examine or remove the container: `pct enter <ctid>` or `pct destroy <ctid> --purge`. |

## How the recipe works

The host script (`create_instance.sh`) has two parts:

- The host part: the wizard, the checks, and the `pveam` and `pct` commands.
- The container part: the `ct_*` functions. The host copies these functions and the answers into
  one installer file. The host sends the file into the container with `pct push`. Then the host
  runs the file with `pct exec`.

Thus, the recipe is one file, and the `wget` command above can run it directly.
