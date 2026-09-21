# Official KingbaseES Base Image

The HA wrapper is verified against this official amd64 Docker archive:

| Field | Value |
| --- | --- |
| KingbaseES version | `V009R001C010B0004` |
| Download | `https://kingbase.oss-cn-beijing.aliyuncs.com/upload/KESV9-baseline/allmode/V009R001C010/docker/KingbaseES_V009R001C010B0004_x86_64_Docker.tar` |
| Archive SHA-256 | `16a436608cc204349e510cb136b8fc1fcbdf6874aee7b204cdac20a3522282da` |
| Loaded image tag | `kingbase_v009r001c010b0004_single_x86:v1` |
| Binary root | `/home/kingbase/install/kingbase` |
| Architecture | `linux/amd64` |

Download the archive from the official download page, then verify and load it:

```bash
shasum -a 256 KingbaseES_V009R001C010B0004_x86_64_Docker.tar
docker load -i KingbaseES_V009R001C010B0004_x86_64_Docker.tar
docker build \
  --build-arg UPSTREAM_IMAGE=kingbase_v009r001c010b0004_single_x86:v1 \
  -t docker.io/wallykk/kingbase:v9r1c10-b0004-21 \
  addons/kingbase/image
```

The official image's default entrypoint is intentionally not used. It initializes
with a default password, modifies cron configuration, and disables SSH host-key
checking. The wrapper only reuses the official KingbaseES binaries and replaces
the entrypoint with the lease-fenced HA supervisor. A customer-provided
`license.dat` remains mandatory at runtime.
