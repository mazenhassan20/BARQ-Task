# BARQ Assessment — Evidence Index

**Video URL:** https://drive.google.com/file/d/1S_DqiIBKWi9MnHA62m-rZXMYTNb8LjZc/view?usp=drive_link
**Final CI Run:** https://github.com/mazenhassan20/BARQ-Task/actions/runs/34405297562

| Requirement | File / Output | Commit Hash | Video Timestamp |
| :--- | :--- | :--- | :--- |
| **Starting Status** | Clean working tree & starting commit | `f7fa810` | [00:25] |
| **Environment Start** | `docker compose up -d` & healthchecks | `f7fa810` | [00:50] |
| **Endpoint Tests** | `/`, `/health`, `/ready`, `/records`, `/counter` | `f7fa810` [01:30] |
| **Load Balancing Proof** | `curl /instance` showing multiple backends | `f7fa810` | [02:20] |
| **Failure/Recovery Test** | `failure_test.py` output | `f7fa810` | [03:00] |
| **Data Persistence** | Record surviving `docker compose rm` | `f7fa810` | [04:30] |
| **Automated Validation** | `validate.py` passing 13/13 | `f7fa810` | [05:20] |
| **Historical Log Finding** | `grep "Connection refused" logs/error.log` | `f7fa810` | [07:10] |
| **Live Challenge Fix** | Diagnosed & fixed `app-01` paused state | `7f21843` |[07:46] |
| **Live Port Change (8090)** | `.env`, `docker-compose.yml` modifications | `7f21843` | [09:35] |
| **Live 3rd Instance** | `docker-compose.yml`, `nginx.conf` modifications | `7f21843` | [10:37] |

*Note: A final documentation-only commit was made after the video recording to update the README, Architecture diagram, and this Evidence Index to match the final three-instance setup on port 8090, as required by the assessment guidelines.*