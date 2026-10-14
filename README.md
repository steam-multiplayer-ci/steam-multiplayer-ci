# steam-multiplayer-ci

Run real Steam multiplayer tests on GitHub-hosted Windows runners.

Each job installs the Steam client, signs in a **dedicated test account**, runs your game or test
program, and uploads its logs. Several jobs in a matrix (one per player) find each other through a
Steam lobby tagged with a per-run marker, so no machine needs to reach another one directly.

```yaml
jobs:
  play:
    runs-on: windows-2025
    timeout-minutes: 20
    strategy:
      fail-fast: false
      matrix:
        role: [0, 1]
    steps:
      - uses: actions/checkout@v7
      - uses: steam-multiplayer-ci/steam-multiplayer-ci@v0
        with:
          steam-username: ${{ matrix.role == 0 && secrets.STEAM_USER_1 || secrets.STEAM_USER_2 }}
          steam-password: ${{ matrix.role == 0 && secrets.STEAM_PASS_1 || secrets.STEAM_PASS_2 }}
          command: .\MyGame.exe --test-mode
          role: ${{ matrix.role }}
          roles: 2
          log-paths: |
            logs/*.log
```

Your program gets three environment variables:

| Variable | Meaning |
|---|---|
| `SMCI_RUN` | A marker unique to this workflow run. Put it in your lobby data so the other players can search for it. |
| `SMCI_ROLE` | This job's player number, starting at 0. Role 0 usually hosts. |
| `SMCI_ROLES` | How many players take part. |

The Steam login is never passed on to your program.

## How the players meet

Role 0 creates a lobby and sets lobby data `smci_run = SMCI_RUN`. The other roles request the lobby
list with a string filter on `smci_run` (worldwide distance), join it, and connect to the lobby owner
with Steam networking. [`examples/spacewar-lobby`](examples/spacewar-lobby) does exactly this with
Valve's public test app Spacewar (app ID 480) and is what this repository's own self-test runs.

## Inputs

| Input | Default | |
|---|---|---|
| `steam-username` / `steam-password` | required | A dedicated test account with Steam Guard turned off (a hosted runner is a new machine every time, so a remembered login cannot be kept). |
| `command` | required | PowerShell command line, run in `working-directory`. |
| `working-directory` | `.` | |
| `role` / `roles` | `0` / `1` | |
| `run-id` | run ID + attempt | Override if your players are split across workflows. |
| `timeout-minutes` | `15` | For your program, after Steam has signed in. |
| `log-paths` | | Newline-separated paths or wildcards (relative to `working-directory`) to upload. |
| `artifact-name` | `smci-logs-role-<role>` | |

Outputs: `exit-code`, `login-seconds`.

## Things to know

- **Use dedicated test accounts only.** Never use your own account. Give each account only the
  licenses the test needs.
- **Logs of public repositories are public.** Do not print secrets. Uploaded artifacts are kept for
  one day. Note that `steam_api64.dll` itself writes the signed-in account's Steam ID to standard error;
  if that matters for your accounts, keep standard error out of the uploaded files or encrypt them.
- The action signs the account out when it finishes, so the login it created is revoked.
- Windows only. Your program needs the Steamworks redistributable (`steam_api64.dll`) from your own
  Steamworks SDK; it is not included here because Valve's terms do not allow redistributing it.
- Steam's own terms apply to the accounts you use.

## Support

Best effort. Bug reports and pull requests are welcome; there is no promise of support.
The parts most likely to break are Steam changing its sign-in screen and GitHub changing its runner
images.

## License

MIT
