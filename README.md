# Centralised rsyslog Logging Server

Receives syslog over UDP/TCP 514 from network devices, firewalls, physical servers, and VMs. Every source is written in a single normalised format, separated into a dedicated per-device folder, with daily log rotation and gzip compression.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Log Directory Structure](#2-log-directory-structure)
3. [Log File Naming](#3-log-file-naming)
4. [Normalised Log Format](#4-normalised-log-format)
5. [Prerequisites](#5-prerequisites)
6. [Step-by-Step Installation](#6-step-by-step-installation)
7. [Configuring Source Devices](#7-configuring-source-devices)
8. [IP-Based Routing (Recommended)](#8-ip-based-routing-recommended)
9. [Log Rotation Details](#9-log-rotation-details)
10. [Verification and Testing](#10-verification-and-testing)
11. [Troubleshooting](#11-troubleshooting)
12. [Project File Layout](#12-project-file-layout)
13. [Graylog Integration](#13-graylog-integration)

---

## 1. Architecture Overview

```text
Network Devices ──┐
Firewalls ─────────┤  UDP/TCP 514   ┌─────────────────────────────────┐
Physical Servers ──┼───────────────▶│  rsyslog server                 │
VMs ───────────────┘                │                                 │
                                    │  rs_routing ruleset             │
                                    │   │                             │
                                    │   ├─▶ rs_cisco_asa              │
                                    │   ├─▶ rs_cisco_ftd              │
                                    │   ├─▶ rs_fortigate              │
                                    │   ├─▶ rs_cisco_ios              │
                                    │   ├─▶ rs_cisco_ios_xe           │
                                    │   ├─▶ rs_cisco_ios_xr           │
                                    │   ├─▶ rs_cisco_nxos             │
                                    │   ├─▶ rs_arista_eos             │
                                    │   ├─▶ rs_mikrotik               │
                                    │   ├─▶ rs_dell                   │
                                    │   ├─▶ rs_hp                     │
                                    │   ├─▶ rs_vm_linux               │
                                    │   ├─▶ rs_vm_windows             │
                                    │   └─▶ rs_unknown                │
                                    │                                 │
                                    │  /var/log/{category}/{type}/    │
                                    │  {hostname}/{hostname}_current  │
                                    └─────────────────────────────────┘
                                              │
                                     logrotate (daily)
                                              │
                                    {hostname}_YYYY-MM-DD.log.gz
```

**Device classification** uses source-IP overrides first (100 % accurate), then falls back to message-content pattern matching.

---

## 2. Log Directory Structure

```text
/var/log/
├── network/                    ← Routers and switches
│   ├── cisco-ios/
│   │   └── <hostname>/
│   │       ├── <hostname>_current.log       ← today (live)
│   │       ├── <hostname>_2026-04-11.log    ← yesterday (uncompressed)
│   │       └── <hostname>_2026-04-10.log.gz ← older (compressed)
│   ├── cisco-ios-xe/
│   ├── cisco-ios-xr/
│   ├── cisco-nxos/
│   ├── arista-eos/
│   ├── mikrotik/
│   └── unknown/
│
├── firewall/                   ← Security perimeter devices
│   ├── cisco-asa/
│   ├── cisco-ftd/
│   └── fortigate/
│
├── compute/                    ← Physical servers
│   ├── dell/
│   └── hp/
│
└── vms/                        ← Virtual machines
    ├── linux/
    └── windows/
```

Top-level category directories and device-type directories are created by `directories.sh`.  
Per-device `<hostname>/` sub-directories are created automatically by rsyslog on first log receipt.

---

## 3. Log File Naming

| File | Description |
| ---- | ----------- |
| `<hostname>_current.log` | Active log file — rsyslog writes here all day |
| `<hostname>_YYYY-MM-DD.log` | Yesterday's log (uncompressed, immediately readable) |
| `<hostname>_YYYY-MM-DD.log.gz` | Logs older than one day (gzip compressed) |

The rename from `_current` to `_YYYY-MM-DD` is handled by the `postrotate` hook in each category's logrotate file.

---

## 4. Normalised Log Format

Every log line — regardless of source vendor — is written in the same format:

```text
2026-04-12T14:30:00+01:00 HOSTNAME facility.severity PROGRAM: message text
```

| Field | Source |
| ----- | ------ |
| Timestamp | RFC 3339 / ISO 8601 (from rsyslog's parsed syslog header) |
| HOSTNAME | Syslog HOSTNAME field sent by the device |
| facility.severity | Syslog facility and severity parsed from PRI octet |
| PROGRAM | Syslog TAG (program name) from the device |
| message | Original message body |

---

## 5. Prerequisites

| Requirement | Notes |
| ----------- | ----- |
| Ubuntu 20.04 LTS or 22.04 LTS | Recommended; Debian 11/12 also works |
| rsyslog 8.x or later | Ships with Ubuntu by default |
| Root / sudo access | Required for all install steps |
| UDP 514 and TCP 514 open inbound | On the rsyslog server's firewall |
| Devices configured to send syslog | See Section 7 |

---

## 6. Step-by-Step Installation

### Step 1 — Install rsyslog

```bash
sudo apt update
sudo apt install rsyslog -y
sudo systemctl enable rsyslog
```

Verify the installed version (must be 8.x+):

```bash
rsyslogd -v
```

---

### Step 2 — Create log directories

Run the included script as root. It creates all category and device-type directories with correct ownership (`syslog:adm`) and permissions (`0750`).

```bash
cd /path/to/rsyslog-server
sudo bash directories.sh
```

Expected output:

```
Creating rsyslog log directory structure under /var/log ...

  [OK]  /var/log/network/cisco-ios
  [OK]  /var/log/network/cisco-ios-xe
  ...
  [OK]  /var/log/vms/windows

Done.
NOTE: Device sub-directories are created on first log receipt.
```

---

### Step 3 — Install rsyslog configuration files

Copy all files from `conf.d/` into `/etc/rsyslog.d/`. The numeric prefix controls load order.

```bash
sudo cp conf.d/*.conf /etc/rsyslog.d/
sudo ls -1 /etc/rsyslog.d/
```

You should see:

```
00-modules.conf
10-templates.conf
20-rulesets-network.conf
21-rulesets-firewall.conf
22-rulesets-compute.conf
23-rulesets-vms.conf
30-routing.conf
50-default.conf    ← already present, managed by Ubuntu
```

---

### Step 4 — Install logrotate configuration

There is one logrotate file per log category. Copy all four into `/etc/logrotate.d/`:

```bash
sudo cp logrotate/network-logs  /etc/logrotate.d/network-logs
sudo cp logrotate/firewall-logs /etc/logrotate.d/firewall-logs
sudo cp logrotate/compute-logs  /etc/logrotate.d/compute-logs
sudo cp logrotate/vm-logs       /etc/logrotate.d/vm-logs
sudo chmod 644 /etc/logrotate.d/network-logs \
               /etc/logrotate.d/firewall-logs \
               /etc/logrotate.d/compute-logs \
               /etc/logrotate.d/vm-logs
```

Verify each file parses without errors:

```bash
sudo logrotate --debug /etc/logrotate.d/network-logs
sudo logrotate --debug /etc/logrotate.d/firewall-logs
sudo logrotate --debug /etc/logrotate.d/compute-logs
sudo logrotate --debug /etc/logrotate.d/vm-logs
```

---

### Step 5 — Open firewall ports

If `ufw` is active on the rsyslog server:

```bash
sudo ufw allow 514/udp comment "syslog UDP"
sudo ufw allow 514/tcp comment "syslog TCP"
sudo ufw reload
sudo ufw status
```

If using `iptables` directly:

```bash
sudo iptables -A INPUT -p udp --dport 514 -j ACCEPT
sudo iptables -A INPUT -p tcp --dport 514 -j ACCEPT
```

---

### Step 6 — Validate and restart rsyslog

**Validate the configuration syntax first** (fix any errors before restarting):

```bash
sudo rsyslogd -N1
```

A clean run prints: `rsyslogd: version ... config validation run (level 1) ... OK`  
Any line starting with `error:` must be resolved before proceeding.

**Restart rsyslog:**

```bash
sudo systemctl restart rsyslog
sudo systemctl status rsyslog
```

**Confirm it is listening on port 514:**

```bash
sudo ss -ulnp | grep 514   # UDP
sudo ss -tlnp | grep 514   # TCP
```

---

## 7. Configuring Source Devices

Replace `<RSYSLOG_IP>` with the IP address of your rsyslog server in every snippet below.

> **Tip:** Configure a meaningful hostname on each device **before** enabling syslog. The device hostname becomes the directory name under its device-type folder and is embedded in every log filename.

---

### Cisco IOS / IOS XE

```
logging host <RSYSLOG_IP> transport udp port 514
logging trap informational
logging facility local7
service timestamps log datetime msec localtime show-timezone year
logging buffered 16384 informational
```

---

### Cisco IOS XR

```
logging <RSYSLOG_IP>
logging facility local7
logging hostnameprefix <device-hostname>
service timestamps log datetime msec localtime show-timezone year
```

---

### Cisco NX-OS

```
logging server <RSYSLOG_IP> 6 use-vrf management facility local7
logging timestamp milliseconds
logging source-interface mgmt0
```

---

### Cisco ASA

```
logging enable
logging host <inside-interface> <RSYSLOG_IP> udp/514
logging trap informational
logging facility 20
logging timestamp
```

Replace `<inside-interface>` with the ASA interface name that can reach the rsyslog server (e.g. `inside` or `management`).

---

### Cisco FTD

Configure via Firepower Management Center (FMC):

1. **Devices → Platform Settings** — create or edit a policy.
2. **Syslog → Syslog Servers** — Add server: IP `<RSYSLOG_IP>`, Protocol UDP, Port 514.
3. **Syslog → Logging Setup** — Enable syslog, severity **Informational**.
4. Deploy the policy to the FTD sensor.

---

### Arista EOS

```
logging host <RSYSLOG_IP>
logging format timestamp high-resolution
logging facility local7
logging on
```

---

### MikroTik RouterBoard

Via CLI (SSH or serial console):

```
/system logging action
add name=remote-syslog target=remote remote=<RSYSLOG_IP> remote-port=514 \
    bsd-syslog=yes syslog-facility=local7

/system logging
add action=remote-syslog topics=info
add action=remote-syslog topics=warning
add action=remote-syslog topics=error
add action=remote-syslog topics=critical
```

Verify with `/system logging print`.

---

### FortiGate

```
config log syslogd setting
    set status enable
    set server "<RSYSLOG_IP>"
    set port 514
    set facility local7
    set format default
end

config log syslogd filter
    set severity information
end
```

The default FortiOS format sends `devname=` and `logid=` key-value pairs — this is the pattern rsyslog uses to classify FortiGate traffic.

---

### Dell Server (iDRAC)

**Via RACADM:**

```bash
racadm set iDRAC.SysLog.SysLogEnable 1
racadm set iDRAC.SysLog.Server1 <RSYSLOG_IP>
racadm set iDRAC.SysLog.PowerLogInterval 5
```

**Via iDRAC web UI:**  
Configuration → System Settings → Remote Syslog → Enable, set Server 1 to `<RSYSLOG_IP>`, Port 514.

---

### HP Server (iLO)

**Via RIBCL / hponcfg** — save as `/tmp/syslog.xml` and apply:

```xml
<RIBCL VERSION="2.0">
  <LOGIN USER_LOGIN="admin" PASSWORD="yourpassword">
    <RIB_INFO MODE="write">
      <MOD_SYSLOG_SETTINGS>
        <SYSLOG_SERVER VALUE="<RSYSLOG_IP>"/>
        <SYSLOG_PORT VALUE="514"/>
      </MOD_SYSLOG_SETTINGS>
    </RIB_INFO>
  </LOGIN>
</RIBCL>
```

```bash
hponcfg -f /tmp/syslog.xml
```

**Via iLO web UI:**  
Administration → Management → Syslog Settings → Remote Syslog Server.

---

### Linux VMs

Add to `/etc/rsyslog.d/50-remote.conf` on the VM:

```
# UDP (fire-and-forget)
*.* @<RSYSLOG_IP>:514

# OR TCP (reliable / ordered)
# *.* @@<RSYSLOG_IP>:514
```

```bash
sudo systemctl restart rsyslog
```

---

### Windows VMs (NXLog)

1. Download and install [NXLog Community Edition](https://nxlog.co/products/nxlog-community-edition).
2. Edit `C:\Program Files (x86)\nxlog\conf\nxlog.conf`:

```
<Extension _syslog>
    Module    xm_syslog
</Extension>

<Input in>
    Module    im_msvistalog
    Query     <QueryList><Query Id="0">
              <Select Path="Application">*</Select>
              <Select Path="System">*</Select>
              <Select Path="Security">*</Select>
              </Query></QueryList>
</Input>

<Output out>
    Module    om_udp
    Host      <RSYSLOG_IP>
    Port      514
    Exec      to_syslog_bsd();
</Output>

<Route 1>
    Path    in => out
</Route>
```

3. Restart the service:

```powershell
Restart-Service nxlog
```

---

## 8. IP-Based Routing (Recommended)

Content-based pattern matching works well but can occasionally misclassify a device if its messages don't match expected patterns. **IP-based routing is 100 % accurate** and should be added for every known device.

Open `conf.d/30-routing.conf` and uncomment/populate the IP override block at the top of `rs_routing`:

```rsyslog
# IP-BASED OVERRIDES — add one line per device
if $fromhost-ip == "10.0.0.1"  then { call rs_cisco_asa    stop }
if $fromhost-ip == "10.0.0.2"  then { call rs_fortigate    stop }
if $fromhost-ip == "10.0.1.1"  then { call rs_cisco_ios    stop }
if $fromhost-ip == "10.0.1.2"  then { call rs_cisco_ios_xe stop }
if $fromhost-ip == "10.0.1.10" then { call rs_cisco_nxos   stop }
if $fromhost-ip == "10.0.1.20" then { call rs_arista_eos   stop }
if $fromhost-ip == "10.0.2.1"  then { call rs_dell         stop }
if $fromhost-ip == "10.0.2.2"  then { call rs_hp           stop }
```

After editing, validate and reload:

```bash
sudo rsyslogd -N1 && sudo systemctl reload rsyslog
```

---

## 9. Log Rotation Details

Logrotate runs daily via `/etc/cron.daily/logrotate`. Each log category has its own configuration file so retention can be tuned independently.

| Category | Config file | Retention | Notes |
| -------- | ----------- | --------- | ----- |
| `network` | `network-logs` | 90 days | Routers and switches |
| `firewall` | `firewall-logs` | 365 days | Extended for audit/compliance |
| `compute` | `compute-logs` | 90 days | Dell and HP servers |
| `vms` | `vm-logs` | 90 days | Linux and Windows VMs |

All four files share the same settings:

| Setting | Value |
| ------- | ----- |
| Schedule | Daily |
| Compression | gzip, applied to logs 2+ days old (`delaycompress`) |
| New file permissions | `0640 syslog adm` |
| rsyslog signal | `SIGHUP` sent in `postrotate` |

**Rotation flow for device `SW-CORE` on 2026-04-12:**

```
Before rotation:
  SW-CORE_current.log               ← today's live log
  SW-CORE_2026-04-11.log            ← yesterday (delaycompress: not yet .gz)
  SW-CORE_2026-04-10.log.gz         ← compressed

logrotate runs:
  1. Renames  SW-CORE_current.log  →  SW-CORE_current_2026-04-12.log
  2. Creates new empty  SW-CORE_current.log  (0640 syslog:adm)
  3. postrotate renames:
        SW-CORE_current_2026-04-12.log  →  SW-CORE_2026-04-12.log
  4. Compresses the now-two-day-old file:
        SW-CORE_2026-04-11.log  →  SW-CORE_2026-04-11.log.gz
  5. Sends SIGHUP to rsyslog → rsyslog reopens SW-CORE_current.log

After rotation:
  SW-CORE_current.log               ← new live log (rsyslog writing here)
  SW-CORE_2026-04-12.log            ← today's rotation (still readable)
  SW-CORE_2026-04-11.log.gz         ← compressed
  SW-CORE_2026-04-10.log.gz
```

**Test without rotating (substitute the file you want to check):**

```bash
sudo logrotate --debug /etc/logrotate.d/network-logs
sudo logrotate --debug /etc/logrotate.d/firewall-logs
sudo logrotate --debug /etc/logrotate.d/compute-logs
sudo logrotate --debug /etc/logrotate.d/vm-logs
```

**Force an immediate rotation of all categories (for testing):**

```bash
for f in network-logs firewall-logs compute-logs vm-logs; do
    sudo logrotate --force /etc/logrotate.d/$f
done
```

---

## 10. Verification and Testing

### Confirm rsyslog is listening

```bash
sudo ss -ulnp | grep 514    # UDP
sudo ss -tlnp | grep 514    # TCP
```

### Send a test UDP syslog message

From any Linux host on the network (install `logger` via `util-linux` if missing):

```bash
logger -n <RSYSLOG_IP> -P 514 --udp -t "TEST" \
  "rsyslog connectivity test from $(hostname)"
```

Expected: a new file appears at  
`/var/log/network/unknown/<sending-hostname>/<sending-hostname>_current.log`

### Simulate a Cisco ASA message

```bash
logger -n <RSYSLOG_IP> -P 514 --udp -t "ASA-FW" \
  "%ASA-6-302013: Built outbound TCP connection 123456 for outside:8.8.8.8/53"
```

Expected: `/var/log/firewall/cisco-asa/<hostname>/<hostname>_current.log`

### Simulate a FortiGate message

```bash
logger -n <RSYSLOG_IP> -P 514 --udp -t "fortigate" \
  "devname=FGT-01 logid=0001000014 type=traffic action=accept"
```

Expected: `/var/log/firewall/fortigate/<hostname>/<hostname>_current.log`

### Watch incoming logs in real time

```bash
# All entries from a specific device
tail -f /var/log/network/cisco-ios/<hostname>/<hostname>_current.log

# rsyslog's own diagnostic output
sudo journalctl -fu rsyslog
```

### Capture raw syslog packets

```bash
sudo tcpdump -i any -n -A port 514
```

---

## 11. Troubleshooting

### No log files are being created

1. Verify rsyslog is listening: `sudo ss -ulnp | grep 514`
2. Capture traffic to confirm packets arrive: `sudo tcpdump -i any -n port 514`
3. Check rsyslog errors: `sudo journalctl -u rsyslog --since "10 minutes ago"`
4. Validate config: `sudo rsyslogd -N1`

### Logs go to `unknown/` instead of the correct category

The device's messages don't match any content detection pattern. Add an IP-based override in `conf.d/30-routing.conf` (Section 8). To inspect the raw message content:

```bash
sudo tcpdump -i any -n -A port 514 | grep -v "^$"
```

### Permission denied when writing log files

The target directory must be owned by `syslog:adm`. Re-run:

```bash
sudo bash directories.sh
```

### logrotate not renaming files correctly

Run the affected category's config in debug mode:

```bash
# Substitute the relevant category file
sudo logrotate --debug --force /etc/logrotate.d/firewall-logs 2>&1 | less
```

Verify the postrotate `find` pattern matches your files:

```bash
find /var/log/network  -name '*_current_*.log' 2>/dev/null
find /var/log/firewall -name '*_current_*.log' 2>/dev/null
find /var/log/compute  -name '*_current_*.log' 2>/dev/null
find /var/log/vms      -name '*_current_*.log' 2>/dev/null
```

### Reloading rsyslog after config changes

```bash
sudo rsyslogd -N1              # always validate first
sudo systemctl reload rsyslog  # graceful reload (no log loss)
```

Use `restart` only if `reload` is insufficient (e.g. after changing module configuration in `00-modules.conf`).

---

## 12. Project File Layout

```text
rsyslog-server/
├── directories.sh                  ← Run once as root: creates /var/log/{category}/{type}/
├── conf.d/
│   ├── 00-modules.conf             ← Load imudp + imtcp
│   ├── 10-templates.conf           ← StandardLogFormat + GELF templates + dynaFile paths
│   ├── 20-rulesets-network.conf    ← Rulesets: cisco-ios/xe/xr, nxos, arista, mikrotik
│   ├── 21-rulesets-firewall.conf   ← Rulesets: cisco-asa, cisco-ftd, fortigate
│   ├── 22-rulesets-compute.conf    ← Rulesets: dell (iDRAC), hp (iLO)
│   ├── 23-rulesets-vms.conf        ← Rulesets: linux VM, windows VM, unknown catch-all
│   ├── 30-routing.conf             ← UDP/TCP inputs + content-based routing logic
│   └── 40-forward-graylog.conf     ← GELF forwarding to Graylog (edit server IP first)
├── logrotate/
│   ├── network-logs                ← /etc/logrotate.d/  routers & switches  (90 days)
│   ├── firewall-logs               ← /etc/logrotate.d/  firewalls           (365 days)
│   ├── compute-logs                ← /etc/logrotate.d/  Dell & HP servers   (90 days)
│   └── vm-logs                     ← /etc/logrotate.d/  Linux & Windows VMs (90 days)
└── graylog/
    ├── docker-compose.yml          ← Reference Graylog stack deployment
    └── .env.example                ← Copy to .env and fill in passwords / host IP
```

---

## 13. Graylog Integration

### Overview

rsyslog writes log files locally **and** simultaneously forwards a structured GELF
copy to Graylog. The two outputs are independent — local files remain the
persistent archive; Graylog provides the search UI, dashboards, and alerting.

Every GELF message carries two extra fields that identify the source:

| GELF field | Example values |
| ---------- | -------------- |
| `_device_category` | `firewall`, `network`, `compute`, `vms`, `unknown` |
| `_device_type` | `cisco-asa`, `cisco-ios`, `fortigate`, `dell`, `linux`, … |

These are set by rsyslog in each device ruleset and indexed automatically by
Graylog — no grok parsing needed to filter by device class.

---

### Step 1 — Deploy Graylog

```bash
cd graylog/
cp .env.example .env
```

Edit `.env`:

```bash
# Set the IP of the machine that will run Graylog (your browser connects here)
GRAYLOG_HOST_IP=192.168.1.100

# Generate a random secret (min 16 chars)
# pwgen -N 1 -s 96
GRAYLOG_PASSWORD_SECRET=<your_random_secret>

# SHA-256 hash of your chosen admin password
# echo -n "YourPassword" | sha256sum | cut -d" " -f1
GRAYLOG_ROOT_PASSWORD_SHA2=<sha256_of_your_password>
```

Start the stack:

```bash
docker compose up -d
docker compose ps          # all three services should be healthy
```

Open `http://<GRAYLOG_HOST_IP>:9000` — log in with username `admin` and the
password you hashed above.

> **Memory note:** OpenSearch is configured for 2 GB heap by default. If your
> host has 8 GB+ RAM, raise `OPENSEARCH_JAVA_OPTS` to `-Xms4g -Xmx4g` in
> `docker-compose.yml` for better performance.

---

### Step 2 — Create the GELF UDP input in Graylog

1. **System → Inputs → Launch new input**
2. Select **GELF UDP** → click **Launch**
3. Set **Port** to `12201`, leave other defaults → **Save**
4. The input should show **Running** within a few seconds

---

### Step 3 — Configure rsyslog to forward to Graylog

Edit `conf.d/40-forward-graylog.conf` and replace the placeholder:

```bash
# On the rsyslog server
sudo nano /etc/rsyslog.d/40-forward-graylog.conf
# Change: server="GRAYLOG_SERVER_IP"
# To:     server="192.168.1.100"   (your actual Graylog IP)
```

Or copy the file from this repo and substitute inline:

```bash
sudo sed 's/GRAYLOG_SERVER_IP/192.168.1.100/' \
    conf.d/40-forward-graylog.conf \
    | sudo tee /etc/rsyslog.d/40-forward-graylog.conf

sudo rsyslogd -N1                  # validate
sudo systemctl restart rsyslog
```

---

### Step 4 — Verify messages are arriving in Graylog

```bash
# Trigger a test message from the rsyslog server itself
logger -n 127.0.0.1 -P 514 --udp -t "TEST" "graylog integration test"
```

In Graylog: **Search** → set time range to **Last 5 minutes** → you should see
the message. Click it and confirm `_device_category` and `_device_type` fields
are present.

---

### Step 5 — Create Streams for each device category

Streams in Graylog act like named buckets — each message is routed to one or
more streams based on field rules.

1. **Streams → Create stream**
2. Name: `Firewalls`, Description: `Cisco ASA, FTD, FortiGate`
3. **Add stream rule**: Field `_device_category` — must match exactly — `firewall`
4. **Start stream**

Repeat for `Network Devices` (`network`), `Compute` (`compute`), `VMs` (`vms`).

---

### Step 6 — Install content packs for vendor parsing

Content packs add ready-made extractors and dashboards for specific device types.

1. **System → Content Packs → Find content packs**
2. Search for and install:
   - **Cisco ASA** — parses `%ASA-severity-msgid:` into structured fields
   - **FortiGate** — parses `key=value` CEF pairs into individual fields
   - **Cisco IOS** — if available
3. Apply each content pack's extractors to the **GELF UDP** input

After extractors are applied, Cisco ASA messages will have indexed fields like
`src_ip`, `dst_ip`, `src_port`, `dst_port`, `action`, `acl_name` — all
searchable and usable in dashboard widgets and alert conditions.

---

### Step 7 — Set up an alert (example)

Alert on Cisco ASA deny events:

1. **Alerts → Event Definitions → Create event definition**
2. **Condition type**: Filter & Aggregation
3. **Search query**: `_device_type:cisco-asa AND action:deny`
4. **Execute every**: 1 minute, **Search within**: 1 minute
5. **Aggregation**: count() > 50
6. **Notifications**: add Slack / email / webhook as required
7. **Save**

---

### Architecture with Graylog

```text
Network Devices ──┐
Firewalls ─────────┤  UDP/TCP 514   ┌──────────────────┐
Physical Servers ──┼───────────────▶│  rsyslog server  │
VMs ───────────────┘                │                  │
                                    │  classify msg    │
                                    │  set metadata    │──▶ /var/log/{category}/
                                    │                  │    (local file archive)
                                    │                  │
                                    └────────┬─────────┘
                                             │ GELF UDP 12201
                                             ▼
                                    ┌──────────────────┐
                                    │  Graylog         │
                                    │  ─────────────── │
                                    │  Streams         │
                                    │  Dashboards      │
                                    │  Alerts          │
                                    │  Content packs   │
                                    └──────────────────┘
```
