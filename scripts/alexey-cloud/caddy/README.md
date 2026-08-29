# Caddy configuration for alexey-cloud

`Caddyfile` here is the tracked copy. The live file is `/etc/caddy/Caddyfile`,
which Caddy actually reads; this directory exists so the configuration is
reproducible and reviewable rather than living only on one host.

Install a change:

```bash
caddy validate --config scripts/alexey-cloud/caddy/Caddyfile --adapter caddyfile
sudo cp -a /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -o root -g root -m 0644 scripts/alexey-cloud/caddy/Caddyfile /etc/caddy/Caddyfile
sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo systemctl reload caddy
```

Confirm the two are in sync:

```bash
diff /etc/caddy/Caddyfile scripts/alexey-cloud/caddy/Caddyfile && echo in-sync
```

Two constraints that are easy to break:

- The listener must stay `bind 127.0.0.1`. Caddy's default for a `:8443` site
  address is every interface, which is how this file started out.
- The site address must NOT name a host (`http://127.0.0.1:8443` was the
  original). `tailscale serve` forwards the tailnet Host header, which would
  not match a host-specific site block, and every request would 404.

Caddy on this host is 2.6.2 (Ubuntu package). It has no global
`servers { trusted_proxies }` option — that arrived in 2.7 — and `handle`
accepts only one inline path matcher, so multi-path routes use named matchers.
