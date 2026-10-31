import { act, render, renderHook, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import { App } from "../src/App";
import { FactCard } from "../src/components/FactCard";
import { clockTime } from "../src/lib/format";
import { DEFAULT_CARD_POLLING, useCard } from "../src/lib/useCard";
import type { CardResponse } from "../src/types";
import {
  cardResponse,
  hit,
  mockApi,
  noCard,
  result,
  teamFacts,
  westchesterEntity,
} from "./fixtures";

const KNICKS = "GET /cards?q=knicks";

const pending = () =>
  cardResponse({
    status: "pending",
    entity: null,
    alternatives: [],
    card: null,
    as_of: null,
    refresh_after_ms: 700,
  });

const unavailable = () => ({ ...pending(), status: "unavailable" as const });

/** A route that answers the given responses in order, then the last one again. */
function sequence(...responses: (CardResponse | Response)[]) {
  let index = 0;
  return () => responses[Math.min(index++, responses.length - 1)];
}

function cardCalls(calls: { key: string }[]) {
  return calls.filter((call) => call.key === KNICKS).length;
}

/** Moves fake time forward and lets the pending requests finish. */
async function tick(ms: number) {
  await act(async () => {
    await vi.advanceTimersByTimeAsync(ms);
  });
}

function setHidden(hidden: boolean) {
  Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
  document.dispatchEvent(new Event("visibilitychange"));
}

afterEach(() => {
  Reflect.deleteProperty(document, "hidden");
});

describe("useCard", () => {
  function setup(...responses: (CardResponse | Response)[]) {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const api = mockApi({ [KNICKS]: sequence(...responses) });
    const hook = renderHook(() => useCard("knicks", DEFAULT_CARD_POLLING));
    return { ...api, hook };
  }

  it("asks again every 0.7 s while pending, then shows the card", async () => {
    const { calls, hook } = setup(pending(), pending(), cardResponse());

    await tick(0);
    expect(cardCalls(calls)).toBe(1);
    expect(hook.result.current).toBeNull();

    await tick(699);
    expect(cardCalls(calls)).toBe(1);
    await tick(1);
    expect(cardCalls(calls)).toBe(2);
    await tick(700);
    expect(cardCalls(calls)).toBe(3);

    expect(hook.result.current?.card?.title).toBe("New York Knicks");
  });

  it("gives up on a card that stays pending for 30 s", async () => {
    const { calls } = setup(pending());

    await tick(31_000);
    const after = cardCalls(calls);
    expect(after).toBeGreaterThan(30);
    expect(after).toBeLessThan(50);

    await tick(120_000);
    expect(cardCalls(calls)).toBe(after);
  });

  it("asks again after refresh_after_ms from the response: 15 s for a live game", async () => {
    const { calls } = setup(cardResponse({ refresh_after_ms: 15_000 }));

    await tick(0);
    expect(cardCalls(calls)).toBe(1);

    await tick(14_999);
    expect(cardCalls(calls)).toBe(1);
    await tick(1);
    expect(cardCalls(calls)).toBe(2);
  });

  it("keeps the cadence within 2-60 s, whatever the server says", async () => {
    const { calls } = setup(
      cardResponse({ refresh_after_ms: 100 }),
      cardResponse({ refresh_after_ms: 3_600_000 }),
    );

    await tick(0);
    await tick(1_999);
    expect(cardCalls(calls)).toBe(1);
    await tick(1);
    expect(cardCalls(calls)).toBe(2);

    await tick(59_999);
    expect(cardCalls(calls)).toBe(2);
    await tick(1);
    expect(cardCalls(calls)).toBe(3);
  });

  it("does not flash the stale notice while a refresh runs, but shows it if the card stays stale", async () => {
    const { hook } = setup(
      cardResponse({ status: "fresh", refresh_after_ms: 15_000 }),
      cardResponse({ status: "stale", refresh_after_ms: 2_000 }),
      cardResponse({ status: "fresh", refresh_after_ms: 15_000, as_of: "2026-10-31T15:42:30Z" }),
      cardResponse({ status: "stale", refresh_after_ms: 2_000, as_of: "2026-10-31T15:42:30Z" }),
      cardResponse({ status: "stale", refresh_after_ms: 2_000, as_of: "2026-10-31T15:42:30Z" }),
    );

    await tick(0);
    expect(hook.result.current?.status).toBe("fresh");

    // Stale for the first time: the refresh is under way. Still shown fresh.
    await tick(15_000);
    expect(hook.result.current?.status).toBe("fresh");
    await tick(2_000);
    expect(hook.result.current?.as_of).toBe("2026-10-31T15:42:30Z");
    expect(hook.result.current?.status).toBe("fresh");

    // Stale again, and still stale 2 s later: the refresh failed.
    await tick(15_000);
    expect(hook.result.current?.status).toBe("fresh");
    await tick(2_000);
    expect(hook.result.current?.status).toBe("stale");
  });

  it("polls a stale card too, and shows it", async () => {
    const { calls, hook } = setup(cardResponse({ status: "stale", refresh_after_ms: 15_000 }));

    await tick(0);
    expect(hook.result.current?.status).toBe("stale");
    await tick(15_000);
    expect(cardCalls(calls)).toBe(2);
  });

  it("stops at once on none: nothing to show, and no more requests", async () => {
    const { calls, hook } = setup(noCard());

    await tick(0);
    expect(hook.result.current).toBeNull();

    await tick(600_000);
    expect(cardCalls(calls)).toBe(1);
  });

  it("retries unavailable after 5, 15 and 30 s, then stops", async () => {
    const { calls, hook } = setup(unavailable());

    await tick(0);
    expect(cardCalls(calls)).toBe(1);
    await tick(5_000);
    expect(cardCalls(calls)).toBe(2);
    await tick(15_000);
    expect(cardCalls(calls)).toBe(3);
    await tick(30_000);
    expect(cardCalls(calls)).toBe(4);

    await tick(600_000);
    expect(cardCalls(calls)).toBe(4);
    expect(hook.result.current).toBeNull();
  });

  it("recovers when unavailable turns into a card", async () => {
    const { hook } = setup(unavailable(), cardResponse());

    await tick(5_000);
    expect(hook.result.current?.status).toBe("fresh");
  });

  it("keeps showing the card while a request fails, then retries on the cadence", async () => {
    const { calls, hook } = setup(
      cardResponse({ refresh_after_ms: 15_000 }),
      new Response("{}", { status: 500 }),
      cardResponse({ refresh_after_ms: 15_000, as_of: "2026-10-31T15:43:00Z" }),
    );

    await tick(15_000);
    expect(cardCalls(calls)).toBe(2);
    expect(hook.result.current?.as_of).toBe("2026-10-31T15:42:15Z");

    await tick(5_000);
    expect(hook.result.current?.as_of).toBe("2026-10-31T15:43:00Z");
  });

  it("sends no request while the tab is hidden, and asks at once when it is visible", async () => {
    const { calls } = setup(cardResponse({ refresh_after_ms: 15_000 }));
    await tick(0);
    expect(cardCalls(calls)).toBe(1);

    act(() => setHidden(true));
    await tick(600_000);
    expect(cardCalls(calls)).toBe(1);

    act(() => setHidden(false));
    await tick(0);
    expect(cardCalls(calls)).toBe(2);

    // And the cadence goes on.
    await tick(15_000);
    expect(cardCalls(calls)).toBe(3);
  });

  it("does not start a request when the timer fires in a hidden tab", async () => {
    const { calls } = setup(cardResponse({ refresh_after_ms: 15_000 }));
    await tick(0);

    // Hidden without a visibilitychange event reaching us: the timer still
    // must not request.
    Object.defineProperty(document, "hidden", { configurable: true, get: () => true });
    await tick(15_000);
    expect(cardCalls(calls)).toBe(1);

    act(() => setHidden(false));
    await tick(0);
    expect(cardCalls(calls)).toBe(2);
  });

  it("asks for the card of the new query and forgets the old one", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    mockApi({
      [KNICKS]: () => cardResponse(),
      "GET /cards?q=nvda": () => noCard(),
    });
    const hook = renderHook(({ query }) => useCard(query), { initialProps: { query: "knicks" } });

    await tick(0);
    expect(hook.result.current?.card?.title).toBe("New York Knicks");

    hook.rerender({ query: "nvda" });
    expect(hook.result.current).toBeNull();
    await tick(0);
    expect(hook.result.current).toBeNull();
  });

  it("does nothing without a query", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout", "Date"] });
    const { calls } = mockApi({});
    const hook = renderHook(() => useCard(null));

    await tick(60_000);
    expect(calls).toEqual([]);
    expect(hook.result.current).toBeNull();
  });
});

describe("FactCard", () => {
  const noop = () => {};

  it("shows the team, league, record, last game, next game and injuries", () => {
    render(<FactCard data={cardResponse()} onSearch={noop} />);

    const card = screen.getByRole("region", { name: "Live facts: New York Knicks" });
    expect(card).toHaveTextContent("New York Knicks");
    expect(card).toHaveTextContent("NBA");
    expect(screen.getByTitle("Record this season")).toHaveTextContent("2-4");

    // Last game: the result, the score (team first) and the opponent.
    expect(screen.getByText("Last game").nextElementSibling).toHaveTextContent(
      /L 93–98 at Philadelphia 76ers/,
    );
    expect(screen.getByText("Next game").nextElementSibling).toHaveTextContent(/vs Brooklyn Nets/);
    expect(screen.getByText("Injuries").nextElementSibling).toHaveTextContent(
      "Jose Alvarado (Out)",
    );
    expect(screen.queryByText("Live")).not.toBeInTheDocument();
  });

  it("shows a game in progress with its score and period", () => {
    const facts = teamFacts({
      live: {
        opponent: "Golden State Warriors",
        home_away: "away",
        team_score: 80,
        opponent_score: 85,
        period: 3,
        clock: "0.0",
        status_text: "End of 3rd",
      },
    });
    render(
      <FactCard
        data={cardResponse({ card: { type: "sports_team", title: "Los Angeles Lakers", facts } })}
        onSearch={noop}
      />,
    );

    const live = screen.getByText("Live").closest(".fact-card__row");
    expect(live).toHaveTextContent("80–85 at Golden State Warriors");
    expect(live).toHaveTextContent("End of 3rd");
  });

  it("omits the rows that have no data", () => {
    const facts = teamFacts({ last_game: null, next_game: null, injuries: [], record: null });
    render(
      <FactCard
        data={cardResponse({ card: { type: "sports_team", title: "Team", facts } })}
        onSearch={noop}
      />,
    );

    expect(screen.queryByText("Last game")).not.toBeInTheDocument();
    expect(screen.queryByText("Next game")).not.toBeInTheDocument();
    expect(screen.queryByText("Injuries")).not.toBeInTheDocument();
    expect(screen.queryByTitle("Record this season")).not.toBeInTheDocument();
  });

  it("stamps the card with the time of the data (seconds for a live game)", () => {
    render(<FactCard data={cardResponse()} onSearch={noop} />);

    const stamp = screen.getByText(clockTime("2026-10-31T15:42:15Z"));
    expect(stamp.tagName).toBe("TIME");
    expect(stamp).toHaveAttribute("datetime", "2026-10-31T15:42:15Z");
    expect(stamp.closest("footer")).toHaveTextContent(/^ESPN\s*as of /);
  });

  it("stamps a live card with seconds", () => {
    const facts = teamFacts({
      live: {
        opponent: "X",
        home_away: "home",
        team_score: 1,
        opponent_score: 2,
        period: 1,
        clock: "1:00",
        status_text: "1:00 - 1st",
      },
    });
    render(
      <FactCard
        data={cardResponse({ card: { type: "sports_team", title: "T", facts } })}
        onSearch={noop}
      />,
    );

    expect(screen.getByText(clockTime("2026-10-31T15:42:15Z", true))).toBeInTheDocument();
  });

  it("says nothing about staleness while the card is fresh", () => {
    render(<FactCard data={cardResponse()} onSearch={noop} />);
    expect(screen.queryByText(/out of date/)).not.toBeInTheDocument();
  });

  it("says the card may be out of date when it is stale, and still shows it", () => {
    render(<FactCard data={cardResponse({ status: "stale" })} onSearch={noop} />);

    expect(screen.getByText("may be out of date")).toBeInTheDocument();
    expect(screen.getByText("New York Knicks")).toBeInTheDocument();
    expect(screen.getByText(clockTime("2026-10-31T15:42:15Z"))).toBeInTheDocument();
  });

  it("lists the alternatives as chips that run a search for their label", async () => {
    const onSearch = vi.fn();
    render(<FactCard data={cardResponse()} onSearch={onSearch} />);

    expect(screen.getByText("also:")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: westchesterEntity.label! }));

    expect(onSearch).toHaveBeenCalledWith("Westchester Knicks");
  });

  it("shows no chips without alternatives", () => {
    render(<FactCard data={cardResponse({ alternatives: [] })} onSearch={noop} />);
    expect(screen.queryByText("also:")).not.toBeInTheDocument();
  });

  it("renders nothing without a card", () => {
    const { container } = render(<FactCard data={noCard()} onSearch={noop} />);
    expect(container).toBeEmptyDOMElement();
  });
});

describe("App with a card", () => {
  const FAST = { intervalMs: 10, timeoutMs: 2000, quietChecks: 2 };

  it("shows the card above the results", async () => {
    window.history.replaceState(null, "", "/?q=knicks");
    mockApi({
      "GET /documents": () => [],
      "POST /search": () => result({ hits: [hit({ title: "Knicks history" })] }),
      [KNICKS]: () => cardResponse(),
    });
    render(<App watch={FAST} />);

    const card = await screen.findByRole("region", { name: "Live facts: New York Knicks" });
    const results = await screen.findByRole("button", { name: "Knicks history" });

    expect(card.compareDocumentPosition(results) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it("shows the results while the card is still pending, and no card", async () => {
    window.history.replaceState(null, "", "/?q=knicks");
    mockApi({
      "GET /documents": () => [],
      "POST /search": () => result({ hits: [hit({ title: "Knicks history" })] }),
      [KNICKS]: () => pending(),
    });
    render(<App watch={FAST} cardPolling={{ ...DEFAULT_CARD_POLLING, pendingMs: 10 }} />);

    expect(await screen.findByRole("button", { name: "Knicks history" })).toBeInTheDocument();
    expect(screen.queryByRole("region", { name: /Live facts/ })).not.toBeInTheDocument();
  });

  it("shows the results when the card request fails", async () => {
    window.history.replaceState(null, "", "/?q=knicks");
    mockApi({
      "GET /documents": () => [],
      "POST /search": () => result({ hits: [hit({ title: "Knicks history" })] }),
      [KNICKS]: () => new Response("{}", { status: 500 }),
    });
    render(<App watch={FAST} />);

    expect(await screen.findByRole("button", { name: "Knicks history" })).toBeInTheDocument();
    expect(screen.queryByRole("alert")).not.toBeInTheDocument();
  });

  it("runs a search for an alternative when its chip is clicked", async () => {
    window.history.replaceState(null, "", "/?q=knicks");
    const { calls } = mockApi({
      "GET /documents": () => [],
      "POST /search": () => result(),
      [KNICKS]: () => cardResponse(),
      "GET /cards?q=Westchester%20Knicks": () => noCard(),
    });
    render(<App watch={FAST} />);

    await userEvent.click(await screen.findByRole("button", { name: "Westchester Knicks" }));

    await waitFor(() => expect(window.location.search).toBe("?q=Westchester+Knicks"));
    await waitFor(() =>
      expect(
        calls.filter(
          (c) => c.key === "POST /search" && JSON.stringify(c.body).includes("Westchester"),
        ),
      ).toHaveLength(1),
    );
    // The card of the new query replaces the old one: none for the G League.
    await waitFor(() =>
      expect(screen.queryByRole("region", { name: /Live facts/ })).not.toBeInTheDocument(),
    );
  });

  it("asks for no card on the home page", async () => {
    const { calls } = mockApi({ "GET /documents": () => [] });
    render(<App watch={FAST} />);

    await screen.findByLabelText("Search query");
    expect(calls.some((c) => c.key.startsWith("GET /cards"))).toBe(false);
  });
});
