#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

DEFAULT_DOMAINS_FILE="/usr/local/bin/default-domains.txt"
PROJECT_DOMAINS_FILE="/workspace/.devcontainer/allowed-domains.txt"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

resolve_domains_from_file() {
  local ipset_name="$1"
  local file_path="$2"

  if [[ ! -f "$file_path" ]]; then
    echo "WARNING: Domain file not found: $file_path (skipping)"
    return 0
  fi

  echo "Loading domains from $file_path..."
  while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ -z "$domain" || "$domain" =~ ^[[:space:]]*# ]] && continue
    domain="${domain//[[:space:]]/}"
    resolve_domain "$ipset_name" "$domain"
  done < "$file_path"
}

resolve_domain() {
  local ipset_name="$1"
  local domain="$2"

  echo "Resolving $domain..."
  local ips
  ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
  if [[ -z "$ips" ]]; then
    echo "WARNING: Failed to resolve $domain (skipping)"
    return 0
  fi

  while read -r ip; do
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
      echo "WARNING: Invalid IP from DNS for $domain: $ip (skipping)"
      continue
    fi
    echo "Adding $ip for $domain"
    ipset add "$ipset_name" "$ip" 2>/dev/null || true
  done <<< "$ips"
}

fetch_github_ips() {
  local ipset_name="$1"

  echo "Fetching GitHub IP ranges..."
  local gh_ranges
  gh_ranges=$(curl -s https://api.github.com/meta)
  if [[ -z "$gh_ranges" ]]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    return 1
  fi

  if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    return 1
  fi

  echo "Processing GitHub IPs..."
  while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
      echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
      return 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add "$ipset_name" "$cidr"
  done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
}

build_full_ipset() {
  local ipset_name="$1"
  local skip_github="${2:-false}"

  if [[ "$skip_github" != true ]]; then
    fetch_github_ips "$ipset_name"
  else
    echo "Skipping GitHub IP fetch (--skip-github)"
  fi

  resolve_domains_from_file "$ipset_name" "$DEFAULT_DOMAINS_FILE"
  resolve_domains_from_file "$ipset_name" "$PROJECT_DOMAINS_FILE"
}

setup_base_iptables() {
  # Extract Docker DNS info BEFORE any flushing
  local docker_dns_rules
  docker_dns_rules=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

  # Flush existing rules and delete existing ipsets
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  ipset destroy allowed-domains 2>/dev/null || true

  # Selectively restore ONLY internal Docker DNS resolution
  if [[ -n "$docker_dns_rules" ]]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$docker_dns_rules" | xargs -L 1 iptables -t nat
  else
    echo "No Docker DNS rules to restore"
  fi

  # Allow DNS, SSH, and localhost before any restrictions
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A INPUT -p udp --sport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
  iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT

  # Allow host network
  local host_ip
  host_ip=$(ip route | grep default | cut -d" " -f3)
  if [[ -z "$host_ip" ]]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
  fi
  local host_network
  host_network=$(echo "$host_ip" | sed "s/\.[0-9]*$/.0\/24/")
  echo "Host network detected as: $host_network"
  iptables -A INPUT -s "$host_network" -j ACCEPT
  iptables -A OUTPUT -d "$host_network" -j ACCEPT

  # Set default policies to DROP
  iptables -P INPUT DROP
  iptables -P FORWARD DROP
  iptables -P OUTPUT DROP

  # Allow established connections
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
}

verify_firewall() {
  echo "Verifying firewall rules..."
  if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
  else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
  fi

  if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
  else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
  fi
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_init() {
  setup_base_iptables

  # Create ipset and populate with all allowed IPs
  ipset create allowed-domains hash:net
  build_full_ipset "allowed-domains"

  # Allow only traffic to allowed domains, reject everything else
  iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
  iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

  echo "Firewall configuration complete"
  verify_firewall
}

cmd_reload() {
  local skip_github=false
  [[ "${1:-}" == "--skip-github" ]] && skip_github=true

  local tmpset="tmp-allowed-$$-${RANDOM}"
  # Clean up temp ipset on error
  trap 'ipset destroy "$tmpset" 2>/dev/null || true' EXIT

  ipset create "$tmpset" hash:net
  build_full_ipset "$tmpset" "$skip_github"
  ipset swap "$tmpset" allowed-domains
  ipset destroy "$tmpset"

  trap - EXIT
  echo "Firewall reloaded (ipset swapped atomically)"
}

cmd_add() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: init-firewall.sh add <domain> [domain...]"
    exit 1
  fi

  for domain in "$@"; do
    resolve_domain "allowed-domains" "$domain"
  done
  echo "Domain(s) added to running firewall"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

case "${1:-init}" in
  init)
    cmd_init
    ;;
  reload)
    shift
    cmd_reload "$@"
    ;;
  add)
    shift
    cmd_add "$@"
    ;;
  *)
    echo "Usage: init-firewall.sh {init|reload|add <domain>}"
    exit 1
    ;;
esac
