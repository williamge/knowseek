# 009. Users and API keys

- Status: parked (no deployment and no users yet)
- Area: new `Knowseek.Accounts` context, web
- Depends on: none

## Goal

Authenticate API calls.

## Scope

- `users` and `api_keys` tables. Store only a hash of each key.
- A plug that reads `Authorization: Bearer <key>` and assigns the current user.
- Documents and the index stay shared across users.
- A mix task to create a user and print a key.

## Acceptance criteria

- Requests without a valid key get 401 (except `/api/health`).
- Tests for the plug.
