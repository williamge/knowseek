import { describe, expect, it } from "vitest";
import { api, ApiError, errorMessage } from "../src/api";
import { mockApi, result } from "./fixtures";

describe("errorMessage", () => {
  it("reads a detail message", () => {
    expect(errorMessage({ errors: { detail: "query is required" } })).toBe("query is required");
  });
  it("joins changeset errors", () => {
    expect(errorMessage({ errors: { query: ["is too short"], refresh: ["is invalid"] } })).toBe(
      "query is too short; refresh is invalid",
    );
  });
  it("returns null for other bodies", () => {
    expect(errorMessage(null)).toBeNull();
    expect(errorMessage({})).toBeNull();
  });
});

describe("api", () => {
  it("unwraps data", async () => {
    mockApi({ "POST /search": () => result() });
    expect((await api.search("octopus")).query).toBe("octopus");
  });

  it("throws ApiError with the server message", async () => {
    mockApi({
      "POST /search": () =>
        new Response(JSON.stringify({ errors: { detail: "query is required" } }), { status: 400 }),
    });
    await expect(api.search("x")).rejects.toMatchObject({
      name: "ApiError",
      status: 400,
      message: "query is required",
    });
    await expect(api.search("x")).rejects.toBeInstanceOf(ApiError);
  });

  it("throws a clear error when a 2xx response has no data", async () => {
    mockApi({ "POST /search": () => new Response("<html>not the API</html>", { status: 200 }) });
    await expect(api.search("x")).rejects.toMatchObject({
      name: "ApiError",
      message: "The API returned an unexpected response.",
    });
  });

  it("handles 204 on delete", async () => {
    mockApi({ "DELETE /topics/t1": () => new Response(null, { status: 204 }) });
    await expect(api.deleteTopic("t1")).resolves.toBeUndefined();
  });
});
