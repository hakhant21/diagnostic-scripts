# Diagnostic and Realtime MYSQL logs script

## Setup and Installation

### Make it executable

```bash
sudo chmod +x diagnostic.sh
```

### Example Usage

```bash
sudo ./diagnostic.sh [option]
```

### Help options to see more

```bash

sudo ./diagnostic.sh help
```

### Full system diagnostic — PHP-FPM status, pool config, memory, CPU, OPCache, Laravel cache, file permissions

```bash
sudo ./diagnostic.sh diagnose
sudo ./diagnostic.sh d
```

### Auto-fix PHP-FPM pool config based on available RAM

```bash
sudo ./diagnostic.sh fix
sudo ./diagnostic.sh f
```

### Maintenance mode → clear caches → rebuild (config, route, view) → fix permissions → bring back up

```bash
sudo ./diagnostic.sh deploy
sudo ./diagnostic.sh dep
```

### Background watcher — restarts PHP-FPM on failure, auto-increases `max_children` on overflow

```bash
sudo ./diagnostic.sh monitor
sudo ./diagnostic.sh m
```

### Stop the background monitor

```bash
sudo ./diagnostic.sh stop-monitor
sudo ./diagnostic.sh sm
```

### Stress test with Apache Bench (URL, concurrent connections, total requests)

```bash
sudo ./diagnostic.sh stress http://example.com 50 1000
```

### Kill all PHP processes, restart Nginx + PHP-FPM + MySQL, clear Laravel caches

```bash
sudo ./diagnostic.sh emergency
sudo ./diagnostic.sh e
```

### Quick status — PHP-FPM running, worker count, free RAM, recent errors, Laravel reachable

```bash
sudo ./diagnostic.sh status
sudo ./diagnostic.sh s
```

## MySQL

### Show full MySQL process list, query statistics, long-running queries, connection count

```bash
sudo ./diagnostic.sh mysql-processes
sudo ./diagnostic.sh mp
```

### View slow query log with statistics (enabled via `mysql-enable-slow`)

```bash
sudo ./diagnostic.sh mysql-slow
sudo ./diagnostic.sh ms
```

### Real-time query monitor — tails the general log for the given duration (default 30s)

```bash
sudo ./diagnostic.sh mysql-monitor 60
```

### Kill a MySQL query by process ID

```bash
sudo ./diagnostic.sh mysql-kill 12345
```

### Enable slow query logging (2s threshold) in MySQL config and restart

```bash
sudo ./diagnostic.sh mysql-enable-slow
```

### MySQL performance dashboard

```bash
sudo ./diagnostic.sh mysql-dashboard
sudo ./diagnostic.sh md
```
