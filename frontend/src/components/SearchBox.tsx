import { useEffect, useRef, useState, type FormEvent, type KeyboardEvent } from "react";

interface Props {
  initialQuery?: string;
  onSearch: (query: string) => void;
  variant: "hero" | "compact";
  autoFocus?: boolean;
}

export function SearchBox({ initialQuery = "", onSearch, variant, autoFocus }: Props) {
  const [value, setValue] = useState(initialQuery);
  const ref = useRef<HTMLTextAreaElement>(null);

  // Follow the URL, for example when the user goes back to an older search.
  useEffect(() => setValue(initialQuery), [initialQuery]);

  // Grow with the text, up to the max-height in CSS.
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }, [value]);

  // Press "/" anywhere to focus the box.
  useEffect(() => {
    const onKeyDown = (event: globalThis.KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      const typing = target?.closest("input, textarea, select, [contenteditable]");
      if (event.key === "/" && !typing && !event.metaKey && !event.ctrlKey) {
        event.preventDefault();
        ref.current?.focus();
        ref.current?.select();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  const submit = (event?: FormEvent) => {
    event?.preventDefault();
    const query = value.trim();
    if (query) onSearch(query);
  };

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing) submit(event);
  };

  return (
    <form className={`search-box search-box--${variant}`} role="search" onSubmit={submit}>
      <textarea
        ref={ref}
        aria-label="Search query"
        placeholder="What do you want to know?"
        rows={1}
        value={value}
        autoFocus={autoFocus}
        onChange={(event) => setValue(event.target.value)}
        onKeyDown={onKeyDown}
      />
      <button type="submit" aria-label="Search" disabled={value.trim() === ""}>
        <svg viewBox="0 0 24 24" aria-hidden="true">
          <path d="M5 12h14M13 6l6 6-6 6" />
        </svg>
      </button>
    </form>
  );
}
