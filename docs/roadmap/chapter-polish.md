# Roadmap: context-aware chapter polish (future iteration)

Status: **designed, not implemented.** This captures the October 2026 planning so a later version can pick it up.

## Goal

Pages are translated one at a time, sentence by sentence. Once a chapter (say 40 pages) is translated, use all of its text to:

- improve wording with context (who is speaking, what happened before)
- fix OCR misreads and typos
- keep names and terms consistent (character names, places, techniques)

Changes are **suggested, then reviewed**. Nothing changes until the user accepts.

## Engine: swappable language-model providers

```swift
protocol LanguageModelProvider: Sendable {
    var name: String { get }
    var contextTokens: Int { get }      // drives chunk sizes
    var acceptsImages: Bool { get }
    func generate<T: Decodable>(_ type: T.Type, schema: JSONSchema, system: String, prompt: String,
                                images: [CGImage]) async throws -> T
}
```

1. **Apple on-device (default):** Foundation Models (`SystemLanguageModel.default`).
   - Free and private.
   - The context is 4K tokens, so passes must be chunked.
   - It runs in a system process (about 1–2 GB while active, outside MangaTL's budget).
   - The macOS 26 SDK has no image input, so the pass is text only.
   - It needs Apple Intelligence: check `availability` and explain `.appleIntelligenceNotEnabled`.
2. **OpenAI-compatible endpoint:** base URL + model + optional key, with structured output via `response_format: json_schema`. This covers local servers (Ollama `http://localhost:11434/v1`, LM Studio), so users can swap models freely, plus hosted services (OpenAI, OpenRouter).
3. **Anthropic (Claude):** API key + editable model id, with structured output via tool use. Check current model ids and API usage against the official docs when implementing.

**Keys:** stored in the macOS Keychain (`SecItem`, service `local.mangatl`). They are never written to `project.json` or git.

**Privacy:** a non-local endpoint needs a one-time confirmation per project ("page text, and images if enabled, will be sent to <host>"). A cloud icon shows while requests run.

**Per project:** a translation-engine setting for page translation (Apple Translation or a provider) and for chapter polish. Providers that accept images get a "send page images" toggle (≤ 1024 px JPEG) for speaker and tone context.

## Passes

1. **Glossary.** Pages are chunked to about 60% of the context.
   - Extract terms: source, English, kind (character, place, organisation, technique, item, other), note.
   - Merge across chunks by majority, keeping variants.
   - Save to `.mangatl/glossary.json`. The user can edit it, and locked entries are never changed.
2. **Story.** A rolling summary of at most 120 words per chunk, in `.mangatl/context.json`.
3. **Refine.** One page per request. The prompt includes:
   - editor instructions: keep the meaning; concise, natural English that fits balloons; fix OCR misreads; follow the glossary; follow the honorifics setting; add nothing
   - the summary so far, the glossary terms on this page, and the last 3 lines of the previous page
   - the page's blocks (id, role, source, current English)

   The output is `PageRevision { changes: [Change{block, english, reason, kind}] }`. If the context window is exceeded, trim the summary, then drop the previous lines.
4. **Deterministic checks** (no model):
   - glossary variant enforcement
   - punctuation clean-up: spacing, `...` → `…`, `?!` order, doubled punctuation, missing final period

## Review flow

- `.mangatl/review.json` holds suggestions: page id, block id, before, after, reason, kind, status. It is written per page, so a pass can resume after quitting.
- **Translate › Polish Chapter…** opens a review sheet:
  - **Changes:** by page, with before → after diff, reason and kind badge. Accept/reject per item, Accept All, **Apply Accepted**, and **Undo Last Apply**.
  - **Glossary:** an editable table plus **Re-check Consistency** (deterministic checks only).
  - **Summary:** read-only.
- The editor shows a badge on blocks with pending suggestions, with accept/reject in the inspector.
- Progress appears in the status bar ("Polishing · Refine 12/40"). Polish and translation never run at the same time.

## Errors

Network errors and HTTP 429 back off and retry 3 times, then skip the page and keep its earlier suggestions. Malformed JSON gets one retry with the parse error appended.

## Tests to write

- glossary merge (majority wins, locked entries respected), variant enforcement, punctuation rules
- review persistence, apply and undo
- providers through a fake `URLProtocol`: request shape, structured-output parsing, retry and back-off
- Keychain round-trip (test service)
- a Foundation Models integration test (when available) on the Japanese samples: valid revisions, the glossary contains "Komona"/"Coriander", and "Comona" is flagged
- smoke: translate → polish → accept all → translations changed → undo restores them; app memory ≤ 250 MB during the pass
