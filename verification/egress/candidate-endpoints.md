# Candidate External Endpoints

## 1. AWS S3

| Field | Decision |
|---|---|
| FQDN | s3.amazonaws.com |
| Port | 443/TCP |
| Component | Cap Web / self-hosted storage path |
| Source evidence | Cap source contains AWS S3 as a configurable/default provider |
| Runtime evidence | Public S3 request from Cap Web failed under deny; internal MinIO health returned HTTP 200 |
| What breaks without it | Nothing in our baseline deployment |
| Classification | Not required |
| Install-time or permanent | Neither |
| Final decision | BLOCK |
| Replacement | Internal MinIO at `cap-minio:9000` |

## 2. Tinybird Analytics

| Field | Decision |
|---|---|
| FQDN | Not enabled in baseline; no external hostname approved |
| Port | 443/TCP if externally hosted |
| Component | Cap Web |
| Source evidence | Analytics tracking route invokes Tinybird; Tinybird configuration is optional |
| Runtime evidence | `TINYBIRD_HOST=<unset>` and `TINYBIRD_TOKEN_SET=no` |
| What breaks without it | External analytics collection; core self-hosted application remains unaffected |
| Classification | Optional / disabled |
| Install-time or permanent | Neither for the baseline |
| Final decision | BLOCK / do not allow |

## 3. cap.so / Vercel Firewall

| Field | Decision |
|---|---|
| FQDN | cap.so / api.vercel.com |
| Port | 443/TCP |
| Component | Cap Web |
| Source evidence | Vercel Firewall integration and Vercel-specific domain-management code |
| Runtime behavior | Vercel Firewall is optional; self-hosted code tolerates its absence |
| What breaks without it | Optional rate limiting / Vercel-specific domain management |
| Classification | Optional vendor functionality |
| Install-time or permanent | Neither for baseline |
| Final decision | BLOCK / no baseline allowlist entry |

## 4. Sentry / OpenTelemetry

| Field | Decision |
|---|---|
| FQDN | No external Sentry/OTLP hostname identified in baseline |
| Port | 443/TCP if an external collector/vendor is configured |
| Component | Cap Web |
| Source evidence | OpenTelemetry tracing code exists, but inspected code does not configure an external exporter |
| Runtime evidence | `SENTRY_DSN`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` are unset |
| What breaks without it | Optional external telemetry/error reporting |
| Classification | Optional / non-required functionality |
| Install-time or permanent | Neither for baseline |
| Final decision | BLOCK / no baseline allowlist entry |

