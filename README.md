# AAAgents — local desktop edition (private)

One command pulls the **full engine + trained models + desktop GUI** to a fresh
PC and launches the app, which runs the whole investment firm **locally with zero
Docker** (SQLite + in-memory state + OS-keychain secrets). The same engine still
runs unchanged in the cloud — the local path is selected purely by environment.

## One command (Windows PowerShell)

On the target PC, install [GitHub CLI](https://cli.github.com) once and run
`gh auth login`, then:

```powershell
& ([scriptblock]::Create((gh api -H "Accept: application/vnd.github.raw" /repos/gorg4444/aaagents-local/contents/bootstrap.ps1)))
```

(or clone + run: `gh repo clone gorg4444/aaagents-local`, then
`powershell -ExecutionPolicy Bypass -File .\aaagents-local\bootstrap.ps1`)

It downloads the release (~6 GB), reassembles + extracts it, sets up a Python
venv with `requirements.oss.txt`, and **launches the desktop app** — which spawns
the no-Docker engine and walks you through entering your Alpaca **paper** keys.

## Prerequisites on the target PC

- **Python 3.12+** on PATH.
- **Ollama** + the model: install from [ollama.com](https://ollama.com), then `ollama pull llama3.2`.
- **GitHub CLI** authenticated (`gh auth login`) — this is a private release.
- Your **Alpaca paper** API keys (entered in-app on first run).

## What's in the release

| Asset | Contents |
|---|---|
| `aaagents-engine.tar.part-*` | the engine **with the trained models** (`core/ml/models`), split into < 2 GB parts |
| `aaagents-gui.tar` | the packaged desktop app (Electron) |
| `SHA256SUMS.txt` | checksums (verified by the bootstrap) |

Excluded from the bundle: secrets (`.env`), runtime DBs/logs, training data, venvs.

## Rebuilding the release (maintainer)

From a machine with the source trees:

```bash
scripts/make-release.sh        # stages the bundle (no secrets), zips+splits, uploads the GitHub Release
```
