#!/bin/bash

# This script must be run as root
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: Please run this script as root"
  exit 1
fi

clear

pause() {
  read -rp "Press Enter to continue..."
}

show_time() {
  echo "===== CURRENT TIME ====="
  timedatectl
  pause
}

ntp_status() {
  echo "===== NTP STATUS ====="
  timedatectl timesync-status 2>/dev/null || echo "NTP service not running"
  pause
}

ntp_on() {
  timedatectl set-ntp true
  systemctl restart systemd-timesyncd 2>/dev/null
  echo "NTP synchronization enabled"
  pause
}

ntp_off() {
  timedatectl set-ntp false
  echo "NTP synchronization disabled"
  pause
}

set_timezone_menu() {
  echo "===== TIME ZONE MENU ====="
  echo "1) Asia/Ho_Chi_Minh"
  echo "2) Asia/Bangkok"
  echo "3) Asia/Singapore"
  echo "4) UTC"
  echo "5) Enter manually"
  echo "0) Back"
  read -rp "Select option: " tz

  case $tz in
    1) timedatectl set-timezone Asia/Ho_Chi_Minh ;;
    2) timedatectl set-timezone Asia/Bangkok ;;
    3) timedatectl set-timezone Asia/Singapore ;;
    4) timedatectl set-timezone UTC ;;
    5)
       read -rp "Enter timezone (example: Europe/London): " custom_tz
       timedatectl set-timezone "$custom_tz"
       ;;
    0) return ;;
    *) echo "Invalid selection" ;;
  esac

  echo "Current timezone:"
  timedatectl | grep "Time zone"
  pause
}

set_manual_time() {
  echo "Manual time setting will DISABLE NTP"
  timedatectl set-ntp false
  read -rp "Enter time (YYYY-MM-DD HH:MM:SS): " manual_time
  timedatectl set-time "$manual_time"
  echo "Time set manually"
  pause
}

rtc_utc() {
  timedatectl set-local-rtc 0
  echo "RTC set to UTC (recommended for servers)"
  pause
}

while true; do
  clear
  echo "=============================="
  echo "  TIME MANAGER - DEBIAN 12"
  echo "=============================="
  echo "1) Show current time"
  echo "2) Check NTP status"
  echo "3) Enable NTP sync"
  echo "4) Disable NTP sync"
  echo "5) Set time zone"
  echo "6) Set time manually"
  echo "7) Set RTC to UTC"
  echo "0) Exit"
  echo "=============================="
  read -rp "Choose an option: " choice

  case $choice in
    1) show_time ;;
    2) ntp_status ;;
    3) ntp_on ;;
    4) ntp_off ;;
    5) set_timezone_menu ;;
    6) set_manual_time ;;
    7) rtc_utc ;;
    0) exit 0 ;;
    *) echo "Invalid option"; pause ;;
  esac
done
