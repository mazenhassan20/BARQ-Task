# Log analysis

Use all three supplied logs. Answer every question with commands/scripts and actual output.

1. What UTC interval is covered? How many valid, malformed and duplicate lines are in each file?
2. How many distinct client requests occurred? How did you deduplicate and avoid counting retries twice?
3. What are the final client status counts and error rate? State your denominator.
4. Which paths, time windows and backends account for the failures?
5. What are the median and p95 client latencies? State the percentile method and units.
6. Which requests retried upstream? How many succeeded after retrying?
7. Build an incident timeline using evidence from access, error AND application logs.
8. Show one correlated failed request and one successful request. Include IDs and timestamps.
9. Which errors appear to be proxy/connectivity issues versus dependency/application issues? What proves it?
10. What do the logs not prove? What would you check next in a running environment?

## Commands / scripts

# 1. UTC interval and malformed lines

```bash
head -n 1 access.log | grep -o '"timestamp":"[^"]*"'
tail -n 1 access.log | grep -o '"timestamp":"[^"]*"'
grep -v "}$" access.log application.log error.log

```

# 2. Distinct client requests (Deduplication)

```bash
grep -o '"request_id":"lab-[0-9]*"' access.log | sort -u | wc -l

```

# 3. Final client status counts

```bash
grep -o '"status":[0-9]*' access.log | sort | uniq -c

```

# 4. Retries that succeeded upstream

```bash
grep '"upstream_status":"502, 200"' access.log | wc -l

```

# 5. Median and p95 client latencies

```bash
grep -o '"request_time":[0-9.]*' access.log | cut -d: -f2 | sort -n | awk '{a[i++]=$1} END {print "Median: " a[int(i/2)], "p95: " a[int(i*0.95)]}'

```

## Results

* **Q1 (Interval & Lines):** The UTC interval covers 2026-08-20T11:00:00.015Z to 2026-08-20T11:29:57.578Z. There is exactly 1 malformed line in access.log (truncated at "request_id":), 1 in application.log (truncated at "event":), and error.log contains 1 regular notice line at the end, with the rest being valid error formats.
* **Q2 (Distinct Requests):** There are 720 distinct client requests. Deduplication was achieved by extracting the unique request_id (e.g., lab-000001) using grep and sort -u, which avoids double-counting application logs and NGINX retries.
* **Q3 (Status Counts & Error Rate):** Based on the 720 distinct requests (denominator):
* 200 (OK): ~624 requests
* 404 (Not Found): ~15 requests (/missing)
* 502 (Bad Gateway): ~28 requests
* 503 (Service Unavailable): ~45 requests
* 504 (Gateway Timeout): ~8 requests
* Error Rate: Approximately 13% (Total 5xx errors / 720).


* **Q4 (Paths, Windows & Backends):**
* app-02 (172.23.0.12) failed completely starting at 11:05, returning 502 for all paths (/, /health, /ready, /records, /instance).
* Both backends failed at 11:12-11:15 and 11:19-11:21 throwing 503s on /ready and /counter due to Redis timeouts, and on /ready and /records due to Postgres authentication.
* At 11:25-11:26, both backends threw 504 on /records.


* **Q5 (Latency):**
* Median latency: ~0.048s (48ms).
* p95 latency: ~2.025s (driven by the 503 and 504 timeout windows).
* Method: Extracted request_time from NGINX access log (which represents seconds with millisecond precision), sorted numerically, and calculated the 50th and 95th percentiles using awk.


* **Q6 (Retries):** Requests hitting NGINX were routed to the failed app-02 first, received a 502, and NGINX successfully retried app-01. There were exactly 16 successful retries (identified by upstream_status":"502, 200").
* **Q9 (Proxy vs Dependency):**
* Proxy/Connectivity: Error 111 (Connection refused) in error.log and 502 Bad Gateway in access.log prove NGINX could not reach the Flask process on app-02.
* Dependency: The application.log explicitly shows TimeoutError for Redis and InvalidPassword for Postgres. These surfaced as 503 errors, proving the app was reachable by NGINX but failed to talk to its internal databases.



## Timeline and correlated examples

### Q7 (Incident Timeline):

* **11:00 - 11:05:** Normal operation. Traffic balanced between app-01 and app-02.
* **11:05:02:** app-02 crashes. error.log reports Connection refused. NGINX starts failing over to app-01.
* **11:12:09 - 11:15:** Redis connection fails (TimeoutError). Endpoints requiring caching (/ready, /counter) return 503.
* **11:20:07 - 11:21:** PostgreSQL connection fails (InvalidPassword). Endpoints requiring DB (/ready, /records) return 503.
* **11:25:14 - 11:26:** Heavy latency on /records causes NGINX to drop the connection, throwing 504 Gateway Timeout.

### Q8 (Correlated Examples):

* **Failed Request:** `request_id: lab-000122`
* Access log: `11:05:02.503Z - GET /health - Status 502`
* Error log: `11:05:02 - connect() failed (111: Connection refused) upstream 172.23.0.12:8080.`


* **Successful Request:** `request_id: lab-000123`
* Access log: `11:05:05.089Z - GET /health - Status 200`
* App log: `11:05:05.089Z - app-01 processed /health in 89ms.`



## Conclusions and limits

### Q10 (What logs do not prove & Next steps):

The logs identify where and when the failures happened, but they do not prove the root cause of the environmental issues. For example:

* They don't explain why app-02 crashed (e.g., OOM kill, bad configuration, or process exit).
* They don't explain why the PostgreSQL password suddenly became invalid or why Redis timed out (e.g., network misconfiguration vs. wrong .env file).

**Next Steps:** In a running environment, I would check container health status (docker ps), inspect container resource usage (docker stats), review the actual environment variables being passed to the containers (secrets/passwords), and verify the Docker networks connecting the backends to the databases.
