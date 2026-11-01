# Run your own Diteko

Diteko generates test calls for Amazon Connect contact flows. This folder runs the whole server
on one machine: the API, the web console, Postgres and Redis. The Python SDK, the MCP server and
the console all talk to it. Each team runs its own, with its own data and its own AWS credentials.

You need Docker with Compose v2 (`docker compose version`), about 2 GB of free memory, and an
x86-64 or arm64 machine (Apple Silicon included). Amazon Connect is optional: without it you can
still import flows, generate tests and export them; only live runs on Connect need AWS.

## 1. Get these files

Download the latest release from <https://github.com/Lehlohonolo-Sehako/diteko-selfhost/releases>
and unpack it on the machine that will run Diteko. It holds `compose.yml`, `.env.example`,
`setup.sh`, this README and the licence. Check the download against `SHA256SUMS` in the release:

```bash
tar xzf diteko-selfhost-*.tar.gz && cd diteko-selfhost
```

## 2. Create the settings

```bash
sh setup.sh
```

It writes `.env` with a random database password and a **bootstrap key**, and prints the key.
The bootstrap key is an admin key you use once, to create real keys. `.env` holds secrets: it is
created readable by you only, and should stay that way.

## 3. Start it

```bash
docker compose up -d
docker compose logs -f app        # wait for "Application 'diteko' is running!", then Ctrl-C
curl -s localhost:8080/api/version
# {"api":"1.2","server":"0.1.0","auth":"keys"}
```

The first start downloads the images and creates the database, which takes a minute or two.
Open `http://localhost:8080` for the console; it asks for an API key once per browser session.

## 4. Create your keys

Every call needs a key (`Authorization: Bearer dk_…`). Each key has one scope, and each scope
includes the ones before it:

| Scope          | Can                                                                |
| -------------- | ------------------------------------------------------------------ |
| `READ`         | see projects and results, export                                   |
| `WRITE`        | create and change, run dry runs. Enough for the SDK's everyday use |
| `PUBLISH_LIVE` | run tests on Amazon Connect (billable) and remove published tests  |
| `ADMIN`        | manage keys                                                        |

Make an `ADMIN` key for yourself with the bootstrap key, either in the console (paste the
bootstrap key, then Settings › API keys) or with `curl`:

```bash
BOOTSTRAP=dk_boot_...   # the key setup.sh printed
curl -s -X POST localhost:8080/api/api-keys \
  -H "Authorization: Bearer $BOOTSTRAP" -H 'Content-Type: application/json' \
  -d '{"name":"My admin key","scope":"ADMIN"}'
```

The answer holds `"secret"`: the key itself. It is shown once; store it in your password manager.
Then make a `WRITE` key the same way (with your new admin key) for each person or script that
uses the SDK.

Finally, retire the bootstrap key: delete the value after `DITEKO_AUTH_BOOTSTRAPKEY=` in `.env`
and run `docker compose up -d`. Anyone holding it could otherwise make keys for themselves.

## 5. Use it from Python

```bash
pip install "diteko[cxblueprint]"
export DITEKO_URL=http://localhost:8080
export DITEKO_API_KEY=dk_...     # a WRITE key
```

```python
from cxblueprint import Flow
from diteko import Diteko

flow = Flow.build("Burger Order")
menu = flow.get_input("Press 1 for Classic or 2 for Veggie", timeout=10)
done = flow.play_prompt("Your order is confirmed!")
sorry = flow.play_prompt("Invalid selection. Goodbye.")
bye = flow.disconnect()
menu.when("1", done).when("2", done).otherwise(sorry)
menu.on_error("InputTimeLimitExceeded", sorry).on_error("NoMatchingCondition", sorry).on_error("NoMatchingError", sorry)
done.then(bye)
sorry.then(bye)

dk = Diteko()
project = dk.projects.from_cxblueprint(flow)
project.grammar.generate()
run = project.evolve(preset="quick").wait(progress=True)
suite = run.suite()
print(suite.export_xlsx("burger-order-tests.xlsx"))   # the manual test script
```

A flow exported from Connect works too: `dk.projects.from_json("my-flow.json")`. The SDK's own
README covers the rest (suites, exports, publishing): <https://pypi.org/project/diteko/>.

For Claude Desktop, Cursor or VS Code, `pip install "diteko[mcp]"` adds an MCP server,
`diteko-mcp`, which reads the same `DITEKO_URL` and `DITEKO_API_KEY`.

## 6. Connect it to Amazon Connect (optional)

Until you do, "Run on Connect" is a dry run: tests are translated and checked locally, and nothing
reaches AWS. Running tests on Connect **creates billable test executions**, so start with a
non-production instance.

1. An IAM principal for Diteko, allowed on your instance: `connect:ListContactFlows`,
   `connect:DescribeContactFlow` (to import flows), `connect:CreateTestCase`,
   `connect:StartTestCaseExecution` and `connect:GetTestCaseExecutionSummary` (to run tests).
2. In `.env`, uncomment and fill in `DITEKO_CONNECT_ENABLED=true`, `DITEKO_CONNECT_REGION`,
   `DITEKO_CONNECT_INSTANCEID` (the UUID at the end of the instance ARN) and the AWS credentials.
3. `docker compose up -d`, then check: `curl -s -H "Authorization: Bearer $KEY" localhost:8080/api/settings/connect`
   answers `"enabled":true`.
4. Live runs need a `PUBLISH_LIVE` key. Give it only to the people and jobs that should spend
   money on your AWS account. Every run stays a dry run unless the caller asks otherwise.

Optional: two hours-of-operation profiles let a test force an hours check open or closed
(`DITEKO_CONNECT_HOURSALWAYSOPEN`, a 24/7 profile; `DITEKO_CONNECT_HOURSNEVEROPEN`, a profile with
an empty schedule). Without them, an hours branch follows the real clock.

## 7. Let your team in

By default Diteko listens on `127.0.0.1` only. To serve other machines, put a reverse proxy with
TLS in front and keep the port private. With [Caddy](https://caddyserver.com/), for example:

```
diteko.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Keys travel in a header on every request, so never serve Diteko over plain HTTP beyond your own
machine. Setting `DITEKO_BIND=0.0.0.0` in `.env` exposes the port directly: do that only on a
private network or VPN.

## Day to day

| Task         | Command                                                                                                                                                                                                                                          |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Status, logs | `docker compose ps`, `docker compose logs -f app`                                                                                                                                                                                                |
| Upgrade      | `docker compose pull && docker compose up -d`, then `docker compose exec redis redis-cli FLUSHALL`. With `DITEKO_VERSION=0.1` that takes the newest 0.1.x; for a new minor version, change it in `.env` first. The database is migrated on start |
| Back up      | `docker compose exec postgres pg_dump -U diteko diteko > diteko-$(date +%F).sql`                                                                                                                                                                 |
| Restore      | `docker compose exec -T postgres psql -U diteko diteko < diteko-2026-10-16.sql` (into an empty database)                                                                                                                                         |
| Stop         | `docker compose down` (data is kept in the `diteko-selfhost_postgres-data` volume)                                                                                                                                                               |
| Remove all   | `docker compose down -v` (**deletes every project and result**)                                                                                                                                                                                  |

Back up before an upgrade. Releases and what changed in each are listed under the repository's
GitHub releases (`server-v…`).

## When something is wrong

- **`run sh setup.sh first`** when starting: `.env` is missing or has no `POSTGRES_PASSWORD`.
- **The app restarts in a loop**: `docker compose logs app`. A database password changed after the
  first start does not match the volume; put the old one back, or `down -v` to start over.
- **401 on every call**: the key is missing, mistyped or revoked. `GET /api/version` needs no key
  and shows whether keys are on.
- **403**: the key's scope is too low for that call (see step 4).
- **Requests fail with `InvalidClassException` after an upgrade**: Redis still holds data cached by
  the previous version. `docker compose exec redis redis-cli FLUSHALL` clears it; nothing is lost.
- **"Import from Connect" answers 409 not configured**: step 6 is not done, or the app was not
  restarted after editing `.env`.

## Support Diteko

Diteko is free to run for your own organisation. If it saves your team time, you can
[sponsor it on GitHub](https://github.com/sponsors/Lehlohonolo-Sehako); the
[docs](https://lehlohonolo-sehako.github.io/diteko-selfhost/support/) list other ways to help.
