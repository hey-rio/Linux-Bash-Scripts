# Linux resource monitor

`linux-resource-monitor.sh` checks the OS first and supports Debian, Ubuntu,
CentOS, RHEL, Rocky Linux, and AlmaLinux. It monitors CPU, RAM, normalized
1-minute load, and configured disks, then sends Telegram alerts with a cooldown.
Every alert includes the primary local IPv4 address. Active incidents are
repeated after `ALERT_COOLDOWN`; when a resource returns below its threshold,
the script sends a `RECOVERED` notification.

## Setup

1. Put the script at a permanent path.
2. Edit the configuration block at the top (especially Telegram token/chat ID).
3. Run `chmod +x linux-resource-monitor.sh`.
4. Run once: `./linux-resource-monitor.sh`.

Send a real Telegram message without waiting for a threshold:

```bash
sudo ./linux-resource-monitor.sh --test
```

Test mode bypasses all thresholds and does not change incident/recovery state.

For a Telegram forum topic, either set `TELEGRAM_CHAT_ID="-1001234567890:42"`
or set the chat ID and `TELEGRAM_MESSAGE_THREAD_ID="42"` separately.

The first run adds one marked entry to the current user's crontab. Later runs do
not duplicate it. Requirements: Bash, `curl`, Linux `/proc`, and `cron`/`cronie`.
Packages are reported when missing and are not installed automatically.
