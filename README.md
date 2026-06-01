# AAAgents — local desktop edition

One command pulls the **full engine + trained models + desktop GUI** to a fresh
PC and launches the app, which runs the whole investment firm **locally with zero
Docker** (SQLite + in-memory state + OS-keychain secrets). The same engine still
runs unchanged in the cloud — the local path is selected purely by environment.

Open-source under the **Apache License 2.0**.

## One command (Windows PowerShell)

```powershell
irm https://raw.githubusercontent.com/gorg4444/aaagents-local/main/bootstrap.ps1 | iex
```

No GitHub login, **no Python install** — both are unnecessary. It downloads the
public release (~7 GB), extracts it, and **launches the desktop app**, which spawns
the no-Docker engine. The dashboard opens in **demo mode** right away; add your
Alpaca **paper** keys in-app to trade. Re-running is safe (downloads resume).

## Prerequisites on the target PC

- An internet connection (for the ~7 GB download). That's the only hard requirement.
- **Python is bundled** in the release — nothing to install.
- *Optional:* **Ollama** for the AI analysis — install from [ollama.com](https://ollama.com),
  then `ollama pull llama3.2`. (The dashboard still opens without it.)
- *Optional:* your **Alpaca paper** API keys, entered in-app, to actually trade.

## What's in the release

| Asset | Contents |
|---|---|
| `aaagents-engine.tar.part-*` | the engine **with the trained models** (`core/ml/models`), split into < 2 GB parts |
| `aaagents-gui.tar` | the packaged desktop app (Electron) |
| `aaagents-python.tar` | a relocatable Python 3.13 with all dependencies (drops the Python prereq) |
| `SHA256SUMS.txt` | checksums (verified by the bootstrap) |

Excluded from the bundle: secrets (`.env`), runtime DBs/logs, training data, venvs.

## License

Apache License 2.0 — see [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE). Bundled
third-party components (PyTorch, LangGraph, FastAPI, Electron, CPython, …) retain
their own licenses.

## Rebuilding the release (maintainer)

From a machine with the source trees (and, for the bundled Python, a prebuilt
`dist/python-bundle/python`):

```bash
scripts/make-release.sh        # tars engine+models+GUI+Python (no secrets), splits, uploads the Release
```
