# server-watch

Host + VM health monitor for this box, alerting through a separate webhook-based alert router (alert-bot, private repo).
Runs as a `systemd` oneshot service on a 2-minute timer - deliberately a plain
bash script outside any of the Python services it watches, so it keeps
working even if one of them (including its own in-process equivalent,
`tasks.watchdog` in madgamehunter_bot) freezes solid.

Checks: Proxmox VM state + qemu-agent ping, mdraid degradation, NVMe SMART
health/wear/temp, disk usage, RAM/swap, load/iowait, systemd failed units,
Docker container restart loops, local HTTP health endpoints, certbot
expiry, pending reboot, and `madgamehunter-worker.service`'s own watchdog
heartbeat (see the comment in `server-watch.sh` for why that last one
exists as a separate, external check).

## Deploy

```
cp server-watch.sh /opt/server-watch/server-watch.sh
cp systemd/*.service systemd/*.timer /etc/systemd/system/
cp config.env.example /etc/server-watch/config.env   # then fill in real values, chmod 600
cp ignore_vmids.txt.example /etc/server-watch/ignore_vmids.txt
systemctl daemon-reload
systemctl enable --now server-watch.timer
```

`/etc/server-watch/config.env` and `/etc/server-watch/ignore_vmids.txt` hold
real secrets/host-specific config - never committed here, only the
`.example` templates.
