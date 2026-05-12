
#!/bin/bash

# COLORS FOR OUTPUT
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# CONFIGURATION
USER=nginx
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null | cut -d. -f1,2)
POOL_FILE="/etc/php-fpm.d/www.conf"
LOG_FILE="/var/log/diagnostic.log"
WATCH_PID_FILE="/tmp/php-fpm-watch.pid"
MYSQL_SLOW_LOG="/var/log/mysql/mysql-slow.log"
MYSQL_ERROR_LOG="/var/log/mysql/error.log"

# FUNCTIONS
print_header() {
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}This option requires root privileges. Run with: sudo $0 $1${NC}"
        exit 1
    fi
}

check_mysql() {
    if ! systemctl is-active --quiet mysql 2>/dev/null && ! systemctl is-active --quiet mariadb 2>/dev/null; then
        echo -e "${RED}MySQL/MariaDB is not running${NC}"
        return 1
    fi
    return 0
}

# OPTION 1: DIAGNOSTIC
diagnostic() {
    print_header "LARAVEL SERVER DIAGNOSTIC"

    echo -e "${YELLOW}1. PHP-FPM Status:${NC}"
    systemctl status php*-fpm --no-pager 2>/dev/null | grep -E "Active|max_children|listen" || echo "PHP-FPM not found"

    echo -e "\n${YELLOW}2. PHP-FPM Pool Configuration:${NC}"
    if [[ -f "$POOL_FILE" ]]; then
        grep -E "^pm\.max_children|^pm\.max_requests|^pm\.start_servers|^pm\.min_spare_servers|^pm\.max_spare_servers|^request_terminate_timeout" "$POOL_FILE" 2>/dev/null || echo "Settings not found"
    else
        echo "Pool file not found at $POOL_FILE"
    fi

    echo -e "\n${YELLOW}3. Active PHP-FPM Processes:${NC}"
    ps aux | grep php-fpm | grep -v grep | wc -l

    echo -e "\n${YELLOW}4. Memory Usage (MB):${NC}"
    free -m | awk 'NR==2{printf "Used: %sMB / Total: %sMB (%.1f%%)\n", $3,$2,$3*100/$2}'

    echo -e "\n${YELLOW}5. CPU Load:${NC}"
    uptime | awk -F'load average:' '{print $2}'

    echo -e "\n${YELLOW}6. Recent PHP-FPM Errors:${NC}"
    tail -n 30 /var/log/php*-fpm.log 2>/dev/null | grep -i error | tail -5 || echo "No errors found"

    echo -e "\n${YELLOW}7. Recent Nginx Errors:${NC}"
    tail -n 20 /var/log/nginx/error.log 2>/dev/null | grep -E "502|504|timeout" | tail -5 || echo "No recent errors"

    echo -e "\n${YELLOW}8. OPCache Status:${NC}"
    php -r "if(function_exists('opcache_get_status')){ \$s=opcache_get_status(false); echo 'Enabled: '.(isset(\$s['opcache_enabled'])?'Yes':'No').'\nMemory: '.round(\$s['memory_usage']['used_memory']/1024/1024,2).'MB / '.round(\$s['memory_usage']['current_memory_usage']/1024/1024,2).'MB';}" 2>/dev/null || echo "OPCache not installed"

    echo -e "\n${YELLOW}10. File Permissions Check:${NC}"
    if [[ -d "storage" ]] && [[ -d "bootstrap/cache" ]]; then
        echo "storage: $(ls -ld storage | awk '{print $1,$3}')"
        echo "bootstrap/cache: $(ls -ld bootstrap/cache 2>/dev/null | awk '{print $1,$3}')"
    else
        echo "Not in Laravel project directory"
    fi
}

# OPTION 2: AUTO-FIX PHP-FPM
fix_phpfpm() {
    check_root "fix"
    print_header "FIXING PHP-FPM CONFIGURATION"

    if [[ ! -f "$POOL_FILE" ]]; then
        echo -e "${RED}Pool file not found at $POOL_FILE${NC}"
        exit 1
    fi

    # Backup
    BACKUP_FILE="${POOL_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$POOL_FILE" "$BACKUP_FILE"
    echo -e "${GREEN}Backup created: $BACKUP_FILE${NC}"

    # Memory-based calculation
    TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    TOTAL_RAM_MB=$((TOTAL_RAM_KB / 1024))

    if [[ $TOTAL_RAM_MB -lt 1024 ]]; then
        MAX_CHILDREN=10
        START_SERVERS=3
        MIN_SPARE=2
        MAX_SPARE=6
    elif [[ $TOTAL_RAM_MB -lt 2048 ]]; then
        MAX_CHILDREN=20
        START_SERVERS=5
        MIN_SPARE=3
        MAX_SPARE=10
    elif [[ $TOTAL_RAM_MB -lt 4096 ]]; then
        MAX_CHILDREN=40
        START_SERVERS=10
        MIN_SPARE=5
        MAX_SPARE=20
    else
        MAX_CHILDREN=60
        START_SERVERS=15
        MIN_SPARE=8
        MAX_SPARE=30
    fi

    echo -e "${YELLOW}Detected RAM: ${TOTAL_RAM_MB}MB, Setting max_children: ${MAX_CHILDREN}${NC}"

    # Update settings
    sed -i 's/^pm =.*/pm = dynamic/' "$POOL_FILE"
    sed -i "s/^pm\.max_children.*/pm.max_children = $MAX_CHILDREN/" "$POOL_FILE"
    sed -i "s/^pm\.start_servers.*/pm.start_servers = $START_SERVERS/" "$POOL_FILE"
    sed -i "s/^pm\.min_spare_servers.*/pm.min_spare_servers = $MIN_SPARE/" "$POOL_FILE"
    sed -i "s/^pm\.max_spare_servers.*/pm.max_spare_servers = $MAX_SPARE/" "$POOL_FILE"
    sed -i 's/^;pm\.max_requests.*/pm.max_requests = 1000/' "$POOL_FILE"
    sed -i 's/^;request_terminate_timeout.*/request_terminate_timeout = 60/' "$POOL_FILE"

    # Add if missing
    grep -q "^pm.max_requests" "$POOL_FILE" || echo "pm.max_requests = 1000" >> "$POOL_FILE"
    grep -q "^request_terminate_timeout" "$POOL_FILE" || echo "request_terminate_timeout = 60" >> "$POOL_FILE"

    # Verify OPCache
    echo -e "\n${YELLOW}Checking OPCache configuration...${NC}"
    INI_FILE="/etc/php/$PHP_VERSION/cli/conf.d/10-opcache.ini"
    if [[ -f "$INI_FILE" ]]; then
        sed -i 's/^;opcache.enable=.*/opcache.enable=1/' "$INI_FILE"
        sed -i 's/^;opcache.memory_consumption=.*/opcache.memory_consumption=256/' "$INI_FILE"
        sed -i 's/^;opcache.max_accelerated_files=.*/opcache.max_accelerated_files=10000/' "$INI_FILE"
        echo -e "${GREEN}OPCache optimized${NC}"
    fi

    # Restart PHP-FPM
    systemctl restart php$PHP_VERSION-fpm
    echo -e "${GREEN}PHP-FPM restarted successfully${NC}"

    # Show new config
    echo -e "\n${YELLOW}New Configuration:${NC}"
    grep -E "^pm\.max_children|^pm\.max_requests|^request_terminate_timeout" "$POOL_FILE"
}

# OPTION 3: DEPLOY LARAVEL CACHES
deploy() {
    print_header "LARAVEL DEPLOYMENT - CACHE OPTIMIZATION"

    if [[ ! -f "artisan" ]]; then
        echo -e "${RED}Not in Laravel project root (artisan not found)${NC}"
        exit 1
    fi

    # Check if in maintenance mode
    if php artisan maintenance:status 2>/dev/null | grep -q "down"; then
        echo -e "${YELLOW}Already in maintenance mode${NC}"
    else
        echo -e "${YELLOW}Putting application in maintenance mode...${NC}"
        php artisan down --retry=60 --message="System maintenance, please wait..." 2>/dev/null || true
    fi

    echo -e "${YELLOW}Clearing all caches...${NC}"
    php artisan optimize:clear 2>/dev/null || true
    php artisan config:clear 2>/dev/null || true
    php artisan route:clear 2>/dev/null || true
    php artisan view:clear 2>/dev/null || true
    php artisan cache:clear 2>/dev/null || true

    echo -e "${YELLOW}Rebuilding optimized caches...${NC}"
    php artisan config:cache 2>/dev/null || true
    php artisan route:cache 2>/dev/null || true
    php artisan view:cache 2>/dev/null || true

    echo -e "${YELLOW}Fixing permissions...${NC}"
    chown -R $USER:$USER storage bootstrap/cache 2>/dev/null || true
    chmod -R 775 storage bootstrap/cache 2>/dev/null || true

    echo -e "${YELLOW}Bringing application back online...${NC}"
    php artisan up 2>/dev/null || true

    echo -e "${GREEN}Deployment complete! Caches rebuilt.${NC}"
}

# OPTION 4: MONITOR
monitor() {
    print_header "STARTING PHP-FPM MONITOR"

    if [[ -f "$WATCH_PID_FILE" ]]; then
        OLD_PID=$(cat "$WATCH_PID_FILE")
        if kill -0 $OLD_PID 2>/dev/null; then
            echo -e "${YELLOW}Monitor already running (PID: $OLD_PID)${NC}"
            echo "Stop with: sudo $0 stop-monitor"
            exit 0
        fi
    fi

    # Background monitoring
    (
        while true; do
            # Check if PHP-FPM is responding
            if ! systemctl is-active --quiet php$PHP_VERSION-fpm 2>/dev/null; then
                echo "[$(date)] PHP-FPM DOWN! Restarting..." | tee -a "$LOG_FILE"
                systemctl restart php$PHP_VERSION-fpm 2>/dev/null
                sleep 10
            fi

            # Check for max_children errors
            if tail -n 20 /var/log/php$PHP_VERSION-fpm.log 2>/dev/null | grep -q "max_children"; then
                echo "[$(date)] MAX CHILDREN REACHED - Increasing limit" | tee -a "$LOG_FILE"
                if [[ -f "$POOL_FILE" ]]; then
                    CURRENT=$(grep "^pm.max_children" "$POOL_FILE" | awk -F'=' '{print $2}' | tr -d ' ')
                    NEW=$((CURRENT + 10))
                    sed -i "s/^pm\.max_children.*/pm.max_children = $NEW/" "$POOL_FILE"
                    systemctl restart php$PHP_VERSION-fpm 2>/dev/null
                    echo "[$(date)] Increased max_children from $CURRENT to $NEW" | tee -a "$LOG_FILE"
                fi
            fi

            # Check for memory leaks
            MEM_USAGE=$(ps aux | grep php-fpm | grep -v grep | awk '{sum+=$6} END {print sum/1024}')
            if (( $(echo "$MEM_USAGE > 80" | bc -l) )); then
                echo "[$(date)] High memory usage: ${MEM_USAGE}MB" | tee -a "$LOG_FILE"
            fi

            sleep 30
        done
    ) &

    echo $! > "$WATCH_PID_FILE"
    echo -e "${GREEN}Monitor started (PID: $(cat $WATCH_PID_FILE))${NC}"
    echo "Log file: $LOG_FILE"
    echo "Stop with: sudo $0 stop-monitor"
}

# OPTION 5: STOP MONITOR
stop_monitor() {
    check_root "stop-monitor"

    if [[ -f "$WATCH_PID_FILE" ]]; then
        PID=$(cat "$WATCH_PID_FILE")
        if kill -0 $PID 2>/dev/null; then
            kill $PID
            echo -e "${GREEN}Monitor stopped (PID: $PID)${NC}"
            rm "$WATCH_PID_FILE"
        else
            echo -e "${YELLOW}Monitor not running${NC}"
            rm "$WATCH_PID_FILE"
        fi
    else
        echo -e "${YELLOW}No monitor PID file found${NC}"
    fi
}

# OPTION 6: STRESS TEST
stress_test() {
    print_header "STRESS TEST"

    URL="${1:-http://localhost}"
    CONCURRENT="${2:-50}"
    REQUESTS="${3:-1000}"

    echo -e "${YELLOW}Testing: $URL${NC}"
    echo -e "${YELLOW}Concurrent: $CONCURRENT | Total Requests: $REQUESTS${NC}"

    # Check if ab is installed
    if ! command -v ab &> /dev/null; then
        echo -e "${RED}Apache Bench (ab) not installed. Install with: sudo apt install apache2-utils${NC}"
        exit 1
    fi

    # Monitor in background
    (
        for i in {1..10}; do
            PROCESS_COUNT=$(ps aux | grep php-fpm | grep -v grep | wc -l)
            echo "[$i] PHP-FPM processes: $PROCESS_COUNT"
            sleep 1
        done
    ) &
    MONITOR_PID=$!

    # Run stress test
    ab -n $REQUESTS -c $CONCURRENT -t 30 "$URL/" 2>&1 | grep -E "Complete|Failed|Requests per second|Time per request|Transfer rate"

    kill $MONITOR_PID 2>/dev/null

    echo -e "\n${YELLOW}Check errors:${NC}"
    tail -5 /var/log/php*-fpm.log 2>/dev/null | grep -i error || echo "No errors found"
}

# OPTION 7: EMERGENCY RESET
emergency_reset() {
    check_root "emergency"
    print_header "EMERGENCY RESET"

    echo -e "${RED}WARNING: This will kill all PHP processes and restart services${NC}"
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    echo -e "${YELLOW}Killing all PHP-FPM processes...${NC}"
    pkill -9 php-fpm 2>/dev/null || true

    echo -e "${YELLOW}Restarting Nginx...${NC}"
    systemctl restart nginx 2>/dev/null || true

    echo -e "${YELLOW}Restarting PHP-FPM...${NC}"
    systemctl restart php$PHP_VERSION-fpm 2>/dev/null || true

    echo -e "${YELLOW}Restarting MySQL...${NC}"
    systemctl restart mysql 2>/dev/null || true

    echo -e "${YELLOW}Clearing Laravel caches...${NC}"
    if [[ -f "artisan" ]]; then
        php artisan optimize:clear 2>/dev/null || true
    fi

    echo -e "${GREEN}Services restarted successfully${NC}"
    echo -e "\n${YELLOW}Service Status:${NC}"
    systemctl status php$PHP_VERSION-fpm nginx mysql --no-pager | grep -E "●|Active"
}

# OPTION 8: QUICK STATUS
quick_status() {
    print_header "QUICK STATUS"

    # PHP-FPM
    if systemctl is-active --quiet php$PHP_VERSION-fpm 2>/dev/null; then
        echo -e "PHP-FPM:  ${GREEN}● Running${NC}"
    else
        echo -e "PHP-FPM:  ${RED}● Stopped${NC}"
    fi

    # Process count
    PROC_COUNT=$(ps aux | grep php-fpm | grep -v grep | wc -l)
    echo -e "Workers:  $PROC_COUNT"

    # Memory
    MEM_FREE=$(free -m | awk 'NR==2{print $4}')
    echo -e "Free RAM: ${MEM_FREE}MB"

    # Recent errors
    ERROR_COUNT=$(tail -n 50 /var/log/php$PHP_VERSION-fpm.log 2>/dev/null | grep -i error | wc -l)
    if [[ $ERROR_COUNT -gt 0 ]]; then
        echo -e "Errors:   ${RED}$ERROR_COUNT in last 50 lines${NC}"
    else
        echo -e "Errors:   ${GREEN}None recent${NC}"
    fi

    # Laravel response
    if curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null | grep -q "200\|302"; then
        echo -e "Laravel:  ${GREEN}Responding${NC}"
    else
        echo -e "Laravel:  ${RED}Not responding${NC}"
    fi
}

# OPTION 9: MYSQL PROCESS LIST
mysql_processes() {
    check_root "mysql-processes"
    print_header "MYSQL PROCESS LIST"

    if ! check_mysql; then
        exit 1
    fi

    echo -e "${YELLOW}Current MySQL Connections & Queries:${NC}\n"

    # Show full process list with formatted output
    mysql -e "SHOW FULL PROCESSLIST" 2>/dev/null | awk '
    BEGIN {
        print "═══════════════════════════════════════════════════════════════════════════════════"
        printf "%-8s | %-8s | %-15s | %-8s | %-20s | %s\n", "ID", "USER", "HOST", "DB", "COMMAND", "TIME"
        print "═══════════════════════════════════════════════════════════════════════════════════"
    }
    NR>1 {
        printf "%-8s | %-8s | %-15s | %-8s | %-20s | %s\n", $1, $2, $3, $4, $5, $6
    }'

    echo -e "\n${YELLOW}Query Statistics:${NC}"

    # Count by state/command
    echo -e "\n${GREEN}By Command Type:${NC}"
    mysql -e "SHOW PROCESSLIST" 2>/dev/null | awk 'NR>1 {count[$5]++} END {for(cmd in count) printf "  %s: %d\n", cmd, count[cmd]}' | sort

    # Long running queries (>10 seconds)
    echo -e "\n${YELLOW}Long Running Queries (>10 seconds):${NC}"
    mysql -e "SHOW PROCESSLIST" 2>/dev/null | awk 'NR>1 && $6>10 {printf "  ID: %s | Time: %ss | State: %s | Query: %.50s\n", $1, $6, $5, $7}'

    # Total connections
    TOTAL_CONN=$(mysql -e "SHOW STATUS LIKE 'Threads_connected'" 2>/dev/null | awk 'NR==2{print $2}')
    MAX_CONN=$(mysql -e "SHOW VARIABLES LIKE 'max_connections'" 2>/dev/null | awk 'NR==2{print $2}')
    echo -e "\n${GREEN}Connections: ${TOTAL_CONN}/${MAX_CONN}${NC}"

    # Kill option prompt
    echo -e "\n${YELLOW}To kill a specific query: sudo $0 mysql-kill <process_id>${NC}"
}

# OPTION 10: MYSQL SLOW QUERY LOG
mysql_slow_queries() {
    check_root "mysql-slow"
    print_header "MYSQL SLOW QUERY LOG"

    if ! check_mysql; then
        exit 1
    fi

    # Check if slow query log is enabled
    SLOW_ENABLED=$(mysql -e "SHOW VARIABLES LIKE 'slow_query_log'" 2>/dev/null | awk 'NR==2{print $2}')

    if [[ "$SLOW_ENABLED" != "ON" ]]; then
        echo -e "${YELLOW}Slow query log is not enabled. Enable it with: sudo $0 mysql-enable-slow-log${NC}"
        echo -e "${YELLOW}Showing recent MySQL errors instead:${NC}\n"
        tail -n 30 "$MYSQL_ERROR_LOG" 2>/dev/null | grep -i "error\|warning" | tail -10 || echo "No errors found"
        exit 0
    fi

    # Get slow log location
    SLOW_LOG=$(mysql -e "SHOW VARIABLES LIKE 'slow_query_log_file'" 2>/dev/null | awk 'NR==2{print $2}')
    SLOW_LOG=${SLOW_LOG:-/var/log/mysql/mysql-slow.log}

    echo -e "${YELLOW}Slow Query Log: $SLOW_LOG${NC}\n"

    if [[ ! -f "$SLOW_LOG" ]]; then
        echo -e "${RED}Slow query log file not found${NC}"
        exit 1
    fi

    # Show top slow queries
    echo -e "${GREEN}Top 10 Slow Queries (by query time):${NC}\n"

    # Parse slow log with mysqldumpslow if available
    if command -v mysqldumpslow &> /dev/null; then
        mysqldumpslow -s t -t 10 "$SLOW_LOG" 2>/dev/null
    else
        # Fallback: show last 20 slow queries
        echo -e "${YELLOW}mysqldumpslow not installed. Showing last 20 slow log entries:${NC}\n"
        tail -n 50 "$SLOW_LOG" | grep -A 5 "# Query_time" | tail -30
    fi

    # Summary statistics
    echo -e "\n${GREEN}Slow Query Statistics:${NC}"
    TOTAL_SLOW=$(grep -c "# Query_time:" "$SLOW_LOG" 2>/dev/null || echo "0")
    echo "  Total slow queries logged: $TOTAL_SLOW"

    if [[ $TOTAL_SLOW -gt 0 ]]; then
        AVG_TIME=$(grep "# Query_time:" "$SLOW_LOG" | awk '{sum+=$3} END {printf "%.2f", sum/NR}')
        echo "  Average query time: ${AVG_TIME}s"
        MAX_TIME=$(grep "# Query_time:" "$SLOW_LOG" | awk '{print $3}' | sort -rn | head -1)
        echo "  Maximum query time: ${MAX_TIME}s"
    fi
}

# OPTION 11: MYSQL QUERY MONITOR (REAL-TIME)
mysql_monitor() {
    check_root "mysql-monitor"
    print_header "REAL-TIME MYSQL QUERY MONITOR"

    if ! check_mysql; then
        exit 1
    fi

    DURATION="${1:-30}"  # Default 30 seconds

    echo -e "${YELLOW}Monitoring MySQL queries for ${DURATION} seconds...${NC}"
    echo -e "${YELLOW}Press Ctrl+C to stop early${NC}\n"

    # Enable general log temporarily
    GENERAL_LOG_STATE=$(mysql -e "SHOW VARIABLES LIKE 'general_log'" 2>/dev/null | awk 'NR==2{print $2}')
    GENERAL_LOG_FILE=$(mysql -e "SHOW VARIABLES LIKE 'general_log_file'" 2>/dev/null | awk 'NR==2{print $2}')

    if [[ "$GENERAL_LOG_STATE" == "OFF" ]]; then
        mysql -e "SET GLOBAL general_log = ON" 2>/dev/null
        echo -e "${GREEN}General query log enabled temporarily${NC}"
        CLEANUP=1
    fi

    # Monitor in real-time
    if [[ -f "$GENERAL_LOG_FILE" ]]; then
        timeout $DURATION tail -f "$GENERAL_LOG_FILE" 2>/dev/null | grep --line-buffered -v "information_schema\|performance_schema" | while read line; do
            if [[ "$line" =~ "Query" ]] || [[ "$line" =~ "Execute" ]]; then
                echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $line"
            fi
        done
    else
        echo -e "${RED}Cannot find general log file${NC}"
    fi

    # Cleanup
    if [[ "$CLEANUP" == "1" ]]; then
        mysql -e "SET GLOBAL general_log = OFF" 2>/dev/null
        echo -e "\n${GREEN}General query log disabled${NC}"
    fi

    echo -e "\n${YELLOW}Query Statistics during monitoring:${NC}"

    # Show current process list summary
    mysql -e "SHOW PROCESSLIST" 2>/dev/null | awk '
    NR>1 {
        count[$5]++
        if($6>5) long[$1]=$6
    }
    END {
        print "  Active queries by command:"
        for(cmd in count) printf "    %s: %d\n", cmd, count[cmd]
        if(length(long)>0) {
            print "\n  Long running queries detected:"
            for(id in long) printf "    ID %s running for %s seconds\n", id, long[id]
        }
    }'
}

# OPTION 12: MYSQL KILL QUERY
mysql_kill() {
    check_root "mysql-kill"

    PROCESS_ID="$1"

    if [[ -z "$PROCESS_ID" ]]; then
        echo -e "${RED}Usage: sudo $0 mysql-kill <process_id>${NC}"
        echo -e "${YELLOW}Get process IDs from: sudo $0 mysql-processes${NC}"
        exit 1
    fi

    if ! check_mysql; then
        exit 1
    fi

    # Verify process exists
    EXISTS=$(mysql -e "SHOW PROCESSLIST" 2>/dev/null | awk -v id="$PROCESS_ID" '$1==id {print $1}')

    if [[ -z "$EXISTS" ]]; then
        echo -e "${RED}Process ID $PROCESS_ID not found${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Killing MySQL query process ID: $PROCESS_ID${NC}"
    mysql -e "KILL $PROCESS_ID" 2>/dev/null

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}Query killed successfully${NC}"
    else
        echo -e "${RED}Failed to kill query${NC}"
    fi
}

# OPTION 13: MYSQL ENABLE SLOW LOG
mysql_enable_slow() {
    check_root "mysql-enable-slow"
    print_header "ENABLING MYSQL SLOW QUERY LOG"

    if ! check_mysql; then
        exit 1
    fi

    MYSQL_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
    if [[ ! -f "$MYSQL_CNF" ]]; then
        MYSQL_CNF="/etc/my.cnf"
    fi

    # Backup config
    cp "$MYSQL_CNF" "${MYSQL_CNF}.backup.$(date +%Y%m%d_%H%M%S)"

    # Add slow query settings if not present
    grep -q "slow_query_log" "$MYSQL_CNF" || echo -e "\n# Slow Query Log Settings\nslow_query_log = 1\nslow_query_log_file = /var/log/mysql/mysql-slow.log\nlong_query_time = 2\nlog_queries_not_using_indexes = 1" >> "$MYSQL_CNF"

    # Update existing settings
    sed -i 's/^#*slow_query_log.*/slow_query_log = 1/' "$MYSQL_CNF"
    sed -i 's/^#*long_query_time.*/long_query_time = 2/' "$MYSQL_CNF"
    sed -i 's/^#*log_queries_not_using_indexes.*/log_queries_not_using_indexes = 1/' "$MYSQL_CNF"

    # Create log file with proper permissions
    touch /var/log/mysql/mysql-slow.log
    chown mysql:mysql /var/log/mysql/mysql-slow.log

    # Restart MySQL
    systemctl restart mysql

    echo -e "${GREEN}Slow query log enabled${NC}"
    echo "  Log file: /var/log/mysql/mysql-slow.log"
    echo "  Threshold: 2 seconds"
    echo ""
    echo -e "${YELLOW}View slow queries with: sudo $0 mysql-slow${NC}"
}

# OPTION 14: MYSQL STATUS DASHBOARD
mysql_dashboard() {
    check_root "mysql-dashboard"
    print_header "MYSQL STATUS DASHBOARD"

    if ! check_mysql; then
        exit 1
    fi

    echo -e "${YELLOW}MySQL Health Check:${NC}\n"

    # Uptime
    UPTIME=$(mysql -e "SHOW STATUS LIKE 'Uptime'" 2>/dev/null | awk 'NR==2{print $2}')
    echo -e "${GREEN}Uptime:${NC} $(($UPTIME/86400)) days $(($UPTIME%86400/3600)) hours"

    # Connections
    CONN_CURRENT=$(mysql -e "SHOW STATUS LIKE 'Threads_connected'" 2>/dev/null | awk 'NR==2{print $2}')
    CONN_MAX=$(mysql -e "SHOW VARIABLES LIKE 'max_connections'" 2>/dev/null | awk 'NR==2{print $2}')
    CONN_TOTAL=$(mysql -e "SHOW STATUS LIKE 'Connections'" 2>/dev/null | awk 'NR==2{print $2}')
    echo -e "${GREEN}Connections:${NC} Current: $CONN_CURRENT / Max: $CONN_MAX (Total: $CONN_TOTAL)"

    # Query stats
    QUERIES=$(mysql -e "SHOW STATUS LIKE 'Questions'" 2>/dev/null | awk 'NR==2{print $2}')
    SLOW=$(mysql -e "SHOW STATUS LIKE 'Slow_queries'" 2>/dev/null | awk 'NR==2{print $2}')
    if [[ $QUERIES -gt 0 ]]; then
        SLOW_PCT=$(echo "scale=2; $SLOW * 100 / $QUERIES" | bc)
    else
        SLOW_PCT=0
    fi
    echo -e "${GREEN}Queries:${NC} Total: $QUERIES | Slow: $SLOW (${SLOW_PCT}%)"

    # Cache hit ratio
    QHITS=$(mysql -e "SHOW STATUS LIKE 'Qcache_hits'" 2>/dev/null | awk 'NR==2{print $2}')
    QINSERTS=$(mysql -e "SHOW STATUS LIKE 'Qcache_inserts'" 2>/dev/null | awk 'NR==2{print $2}')
    if [[ $(($QHITS + $QINSERTS)) -gt 0 ]]; then
        HIT_RATIO=$(echo "scale=2; $QHITS * 100 / ($QHITS + $QINSERTS)" | bc)
    else
        HIT_RATIO=0
    fi
    echo -e "${GREEN}Query Cache:${NC} Hit ratio: ${HIT_RATIO}%"

    # InnoDB buffer pool
    BP_HIT=$(mysql -e "SHOW STATUS LIKE 'Innodb_buffer_pool_reads'" 2>/dev/null | awk 'NR==2{print $2}')
    BP_REQ=$(mysql -e "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests'" 2>/dev/null | awk 'NR==2{print $2}')
    if [[ $BP_REQ -gt 0 ]]; then
        BP_HIT_RATIO=$(echo "scale=2; (1 - $BP_HIT/$BP_REQ) * 100" | bc)
    else
        BP_HIT_RATIO=0
    fi
    echo -e "${GREEN}InnoDB Buffer Pool:${NC} Hit ratio: ${BP_HIT_RATIO}%"

    # Top tables by size
    echo -e "\n${YELLOW}Largest Tables (Top 10 by size):${NC}"
    mysql -e "SELECT table_schema, table_name, ROUND(((data_length + index_length) / 1024 / 1024), 2) AS 'Size_MB' FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys') ORDER BY (data_length + index_length) DESC LIMIT 10;" 2>/dev/null | column -t

    # Recommendation based on slow queries
    if [[ $SLOW -gt 100 ]]; then
        echo -e "\n${RED}⚠ High number of slow queries detected!${NC}"
        echo -e "${YELLOW}Recommendation: Review slow query log: sudo $0 mysql-slow${NC}"
    fi

    if [[ $CONN_CURRENT -gt $(($CONN_MAX * 80 / 100)) ]]; then
        echo -e "\n${RED}⚠ Connection pool near limit!${NC}"
        echo -e "${YELLOW}Recommendation: Increase max_connections or optimize connection handling${NC}"
    fi
}

# HELP FUNCTION
show_help() {
    echo -e "${GREEN}Laravel PHP-FPM & MySQL Management Script${NC}"
    echo ""
    echo "Usage: sudo $0 [OPTION] [ARGS]"
    echo ""
    echo "=== PHP-FPM Options ==="
    echo "  diagnose | d          - Run full system diagnostic"
    echo "  fix | f               - Auto-fix PHP-FPM configuration"
    echo "  deploy | dep          - Clear and rebuild Laravel caches"
    echo "  monitor | m           - Start background monitoring"
    echo "  stop-monitor | sm     - Stop background monitoring"
    echo "  stress [url] [c] [n]  - Run stress test (url, concurrent, requests)"
    echo "  emergency | e         - Emergency reset (kill all PHP processes)"
    echo "  status | s            - Quick status check"
    echo ""
    echo "=== MySQL Options ==="
    echo "  mysql-processes | mp  - Show MySQL process list and active queries"
    echo "  mysql-slow | ms       - Show MySQL slow query log"
    echo "  mysql-monitor [sec]   - Real-time MySQL query monitor (default: 30s)"
    echo "  mysql-kill <id>       - Kill a specific MySQL query"
    echo "  mysql-enable-slow     - Enable MySQL slow query logging"
    echo "  mysql-dashboard | md  - MySQL performance dashboard"
    echo ""
    echo "Examples:"
    echo "  sudo $0 diagnose"
    echo "  sudo $0 fix"
    echo "  sudo $0 mysql-processes"
    echo "  sudo $0 mysql-monitor 60"
    echo "  sudo $0 mysql-kill 12345"
    echo "  sudo $0 mysql-dashboard"
    echo ""
    echo "Log file: $LOG_FILE"
    echo "MySQL slow log: /var/log/mysql/mysql-slow.log"
}

# MAIN SWITCH
case "$1" in
    # PHP-FPM Options
    diagnose|d)
        diagnostic
        ;;
    fix|f)
        fix_phpfpm
        ;;
    deploy|dep)
        deploy
        ;;
    monitor|m)
        monitor
        ;;
    stop-monitor|sm)
        stop_monitor
        ;;
    stress)
        stress_test "$2" "$3" "$4"
        ;;
    emergency|e)
        emergency_reset
        ;;
    status|s)
        quick_status
        ;;
    # MySQL Options
    mysql-processes|mp)
        mysql_processes
        ;;
    mysql-slow|ms)
        mysql_slow_queries
        ;;
    mysql-monitor)
        mysql_monitor "$2"
        ;;
    mysql-kill)
        mysql_kill "$2"
        ;;
    mysql-enable-slow)
        mysql_enable_slow
        ;;
    mysql-dashboard|md)
        mysql_dashboard
        ;;
    help|h|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown option: $1${NC}"
        echo ""
        show_help
        exit 1
        ;;
esac
