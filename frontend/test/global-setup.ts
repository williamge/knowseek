/**
 * Runs once in the main process, before the test workers start, so that every
 * worker inherits it. Tests that show clock times assert exact strings, which
 * need a fixed time zone.
 */
export function setup() {
  process.env.TZ = "America/New_York";
}
