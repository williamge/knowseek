# Security policy

## Reporting a vulnerability

Report vulnerabilities privately with GitHub private vulnerability reporting: open the repository's **Security** tab, then **Report a vulnerability**. Do not open a public issue or pull request for a vulnerability.

## Scope

In scope: the code in this repository (the Phoenix API in `backend/`, the web UI in `frontend/`, the Docker and compose files, the CI workflow), for example injection, leaking secrets, or a bypass of a documented limit.

Out of scope: the missing authentication (see below), the committed dev and test `secret_key_base` values (local use only), vulnerabilities in third-party dependencies that this code does not trigger (report them upstream), and denial of service by a client with unrestricted access to an unprotected API.

## Known limitation: no authentication

The API has no authentication yet (task 009, parked). Anyone who can reach it can read and write the index and trigger outbound requests to external sources. It is **not meant to be deployed on the public internet as it is**. Run it on localhost or behind your own access control. `/dev/dashboard` exists only in the dev environment.

## Supported versions

Only the `main` branch is supported. There are no releases yet.
