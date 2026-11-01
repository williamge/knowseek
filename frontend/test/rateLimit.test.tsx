import { act, render, renderHook, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { ApiError, api, rateLimitDelayMs } from "../src/api";
import { DEFAULT_CARD_POLLING, useCard } from "../src/lib/useCard";
import { MAX_RATE_LIMIT_RETRIES, useSearch } from "../src/lib/useSearch";
import type { SearchResult } from "../src/types";
import { cardResponse, document as doc, hit, mockApi, result } from "./fixtures";

const KNICKS = "GET /cards?q=knicks";

/** What the server answers over the limit: 429, the error body, `Retry-After`. */
function limited(retryAfter?: string) {
  return new Response(JSON.stringify({ errors: { detail: "Too many requests" } }), {
    status: 429,
    headers: retryAfter === undefined ? {} : { "retry-after": retryAfter },
  });
}

/** A route that answers the given responses in order, then the last one again. */
function sequence<T>(...responses: T[]) {
  let index = 0;
  return () => responses[Math.min(index++, responses.length - 1)];
}

async function tick(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}

const count = (calls: { key: string }[], key: string) =>
  calls.filter((call) => call.key === key).length;

afterEach(() => {
  vi.useRealTimers();
});

describe("api: 429", () => {
  it("reads Retry-After in seconds into the ApiError", async () => {
    mockApi({ "POST /search": () => limited("20") });
    const error = await api.search("x").catch((e: unknown) => e);

    expect(error).toBeInstanceOf(ApiError);
    expect(error).toMatchObject({
      status: 429,
      message: "Too many requests",
      retryAfterMs: 20_000,
    });
  });

  it("has no retryAfterMs without a usable header", async () => {
    mockApi({
      "POST /search": sequence<SearchResult | Response>(
        limited(),
        limited("Wed, 21 Oct 2026 07:28:00 GMT"),
        limited("-3"),
      ),
    });

    for (let i = 0; i < 3; i++) {
      await expect(api.search("x")).rejects.toMatchObject({ status: 429, retryAfterMs: null });
    }
  });

  it("rateLimitDelayMs keeps the wait within 1-60 s, and is null for other errors", () => {
    const error = (ms: number | null) => new ApiError(429, "Too many requests", ms);

    expect(rateLimitDelayMs(error(20_000))).toBe(20_000);
    expect(rateLimitDelayMs(error(0))).toBe(1000);
    expect(rateLimitDelayMs(error(3_600_000))).toBe(60_000);
    expect(rateLimitDelayMs(error(null))).toBe(5000);
    expect(rateLimitDelayMs(new ApiError(500, "boom", 20_000))).toBeNull();
    expect(rateLimitDelayMs(new Error("network"))).toBeNull();
  });
});

describe("useCard: 429", () => {
  function setup(...responses: unknown[]) {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const api = mockApi({ [KNICKS]: sequence(...responses) });
    const hook = renderHook(() => useCard("knicks", DEFAULT_CARD_POLLING));
    return { ...api, hook };
  }

  it("waits for Retry-After, then asks again", async () => {
    const { calls, hook } = setup(limited("20"), cardResponse());

    await tick(0);
    expect(count(calls, KNICKS)).toBe(1);

    await tick(19_999);
    expect(count(calls, KNICKS)).toBe(1);
    await tick(1);
    expect(count(calls, KNICKS)).toBe(2);
    expect(hook.result.current?.card?.title).toBe("New York Knicks");
  });

  it("does not loop hot on Retry-After 0: at least one second between requests", async () => {
    const { calls } = setup(limited("0"));

    await tick(0);
    expect(count(calls, KNICKS)).toBe(1);
    await tick(999);
    expect(count(calls, KNICKS)).toBe(1);
    await tick(1);
    expect(count(calls, KNICKS)).toBe(2);

    // Many 429s in a row: still one request a second at the most.
    await tick(60_000);
    expect(count(calls, KNICKS)).toBeLessThanOrEqual(62);
  });

  it("waits at most a minute, and five seconds without a Retry-After", async () => {
    const { calls } = setup(limited("3600"), limited());

    await tick(0);
    await tick(59_999);
    expect(count(calls, KNICKS)).toBe(1);
    await tick(1);
    expect(count(calls, KNICKS)).toBe(2);

    await tick(4_999);
    expect(count(calls, KNICKS)).toBe(2);
    await tick(1);
    expect(count(calls, KNICKS)).toBe(3);
  });

  it("keeps the card on screen, fresh, however long it is limited", async () => {
    const { calls, hook } = setup(cardResponse({ refresh_after_ms: 15_000 }), limited("20"));

    await tick(0);
    expect(hook.result.current?.status).toBe("fresh");

    // Far more than the retries of a failing source (5+15+30+60+90 s).
    await tick(15_000 + 20_000 * 20);
    expect(count(calls, KNICKS)).toBe(22);
    expect(hook.result.current?.status).toBe("fresh");
    expect(hook.result.current?.card?.title).toBe("New York Knicks");
  });

  it("does not use up the retries of a failing source", async () => {
    const unavailable = cardResponse({
      status: "unavailable",
      entity: null,
      card: null,
      as_of: null,
      refresh_after_ms: 30_000,
    });
    const { calls } = setup(limited("2"), limited("2"), limited("2"), unavailable);

    await tick(6_000);
    expect(count(calls, KNICKS)).toBe(4);

    // The first retry after `unavailable` is 5 s, not a later step of the schedule.
    await tick(4_999);
    expect(count(calls, KNICKS)).toBe(4);
    await tick(1);
    expect(count(calls, KNICKS)).toBe(5);
  });

  it("shows nothing: no error, no message", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    mockApi({
      "GET /documents": () => [],
      [KNICKS]: () => limited("20"),
      "POST /search": () => result(),
    });
    window.history.replaceState(null, "", "/?q=knicks");
    render(<App />);

    await tick(100);

    expect(screen.queryByRole("alert")).toBeNull();
    expect(screen.queryByText(/too many requests/i)).toBeNull();
  });
});

describe("useSearch: 429", () => {
  const WATCH = { intervalMs: 1000, timeoutMs: 600_000, quietChecks: 2 };

  function fakeTimers() {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
  }

  it("is not an error: it waits for Retry-After and asks again", async () => {
    fakeTimers();
    const { calls } = mockApi({
      "GET /documents": () => [],
      "POST /search": sequence<SearchResult | Response>(
        limited("20"),
        result({ hits: [hit({ title: "Octopus" })] }),
      ),
    });
    const hook = renderHook(() => useSearch("octopus", WATCH));

    await tick(0);
    expect(hook.result.current).toEqual({
      status: "rate_limited",
      query: "octopus",
      retryAfterMs: 20_000,
    });

    await tick(19_999);
    expect(count(calls, "POST /search")).toBe(1);
    await tick(1);
    expect(count(calls, "POST /search")).toBe(2);
    expect(hook.result.current.status).toBe("done");
  });

  it("gives up with the server's message after a few 429s in a row, never hot", async () => {
    fakeTimers();
    const { calls } = mockApi({
      "GET /documents": () => [],
      "POST /search": () => limited("0"),
    });
    const hook = renderHook(() => useSearch("octopus", WATCH));

    await tick(0);
    expect(count(calls, "POST /search")).toBe(1);
    expect(hook.result.current.status).toBe("rate_limited");

    // One request a second at the most, then it stops.
    await tick(60_000);
    expect(count(calls, "POST /search")).toBe(MAX_RATE_LIMIT_RETRIES + 1);
    expect(hook.result.current).toEqual({
      status: "error",
      query: "octopus",
      error: "Too many requests",
    });
  });

  it("stops asking when the query changes while it waits", async () => {
    fakeTimers();
    const { calls } = mockApi({
      "GET /documents": () => [],
      "POST /search": () => limited("20"),
    });
    const hook = renderHook(({ query }) => useSearch(query, WATCH), {
      initialProps: { query: "octopus" as string | null },
    });

    await tick(0);
    hook.rerender({ query: null });
    await tick(120_000);

    expect(count(calls, "POST /search")).toBe(1);
    expect(hook.result.current.status).toBe("idle");
  });

  it("keeps the results when a search for new documents is limited, and checks again after Retry-After", async () => {
    fakeTimers();
    let listCalls = 0;
    const { calls } = mockApi({
      "GET /documents": () => {
        listCalls += 1;
        return listCalls === 1 ? [doc({ id: "old" })] : [doc({ id: "new" }), doc({ id: "old" })];
      },
      "POST /search": sequence<SearchResult | Response>(
        result({
          coverage: "none",
          discovery: { status: "enqueued", job_id: 1 },
          hits: [hit({ document_id: "old", title: "Old" })],
        }),
        limited("10"),
        result({ hits: [hit({ document_id: "new", chunk_id: "n", title: "Fresh" })] }),
      ),
    });
    const hook = renderHook(() => useSearch("octopus", WATCH));

    await tick(0);
    expect(hook.result.current.status).toBe("done");

    // The check at 1 s finds a new document; its search is limited.
    await tick(1_000);
    expect(count(calls, "POST /search")).toBe(2);
    expect(hook.result.current).toMatchObject({ status: "done", watching: true });

    // Not at the usual 1 s, but after Retry-After.
    await tick(9_999);
    expect(count(calls, "POST /search")).toBe(2);
    await tick(1);
    expect(count(calls, "POST /search")).toBe(3);
    expect(hook.result.current).toMatchObject({ status: "done", discovered: 1 });
  });
});

describe("App: 429", () => {
  it("shows a muted message instead of an error, then the results", async () => {
    window.history.replaceState(null, "", "/?q=octopus");
    mockApi({
      "GET /documents": () => [],
      "POST /search": sequence<SearchResult | Response>(
        limited("1"),
        result({ hits: [hit({ title: "Octopus" })] }),
      ),
    });
    render(<App />);

    const message = await screen.findByText("Too many requests, retrying shortly");
    expect(message).toHaveClass("muted");
    expect(screen.queryByRole("alert")).toBeNull();

    expect(
      await screen.findByRole("button", { name: "Octopus" }, { timeout: 3000 }),
    ).toBeInTheDocument();
    expect(screen.queryByText("Too many requests, retrying shortly")).toBeNull();
  });
});
