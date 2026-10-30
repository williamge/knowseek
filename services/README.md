# services/

Background services that are not part of the Elixir backend live here, one
directory per service (for example `services/extractor/` for a Python
HTML-to-text extractor).

The Elixir backend in `backend/` owns the database schema and the public API.
Before you add a service here:

1. Write an ADR in `docs/decisions/` that explains why it is a separate
   service and which language it uses.
2. Define the contract with the backend. Preferred options, in order:
   - The backend calls the service over HTTP (simple, easy to test with stubs).
   - The service consumes jobs that the backend enqueues (for long-running work).
   Do not let a service write directly to backend-owned tables.
3. Add the service to `docker-compose.yml`, the `Makefile`, and CI.
4. Give the service its own `AGENTS.md` with build and test commands.
