# Transfer and verify the guide

The archive has one top-level `typesafe-agent-guide/` directory. Unzip it, read `README.md`, and run the offline example/tests before adapting live mode. `SHA256SUMS` lists the bundled files except itself; it detects accidental changes, not malicious replacement of both files and manifest.

On the sending machine, list available Taildrop targets and copy the archive:

```bash
tailscale file cp --targets
tailscale file cp ./typesafe-agent-guide-2026-09-21.zip DESTINATION:
```

Replace `DESTINATION` with a target shown by the first command. Keep the trailing colon. The target must be eligible for Taildrop under your tailnet configuration. These commands were checked against the installed Tailscale CLI; this guide does not send a file automatically.

On a Linux receiver, move the arrived file out of the Taildrop inbox:

```bash
mkdir -p ~/Downloads
tailscale file get --conflict=rename ~/Downloads
```

Other operating systems may expose received files through the Tailscale UI. Transfer availability is separate from SSH; a Tailscale connection alone does not enable an SSH server.

After extraction, on a system with GNU coreutils:

```bash
cd typesafe-agent-guide
sha256sum --check SHA256SUMS
python3 examples/rank_evidence.py
python3 -m unittest discover -s examples -p 'test_*.py' -v
```

The archive contains source/documentation and a synthetic offline fixture, not credentials or a ready-to-deploy service. Live use requires reviewing the source-transmission scope and supplying your own secret reference/model configuration. Read [architecture](02-architecture-and-operations.md) and [examples](examples/README.md).
