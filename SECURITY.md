# Security Policy

## Supported versions

This edition is maintained as a Docker image only. Use the `latest` tag on
[Docker Hub](https://hub.docker.com/r/andyxtreme/youtubedl-material) — fixed
version tags (e.g. `1.0`) exist for pinning, but only `latest` receives updates.

| Version | Supported |
| --- | --- |
| `latest` | :white_check_mark: |
| fixed tags (`1.0`, …) | :x: (snapshots, no backports) |

## Scope

This is a downstream image of
[YoutubeDL-Material](https://github.com/Tzahi12345/YoutubeDL-Material). Changes
here are limited to the container build (Dockerfile, compose, build-time
patches). Vulnerabilities in the application itself belong upstream; anything
about the image, the build, or the patches belongs here.

## Reporting

Please open an issue at
<https://github.com/AndyXtreme/YoutubeDL-Material/issues>.

## Exposure

The application is meant to run **on your LAN**, not as a public instance. It is
not hardened for direct internet exposure — put it behind a reverse proxy with
authentication if it has to be reachable from outside, and treat the API and the
file manager as trusted-network surfaces.
